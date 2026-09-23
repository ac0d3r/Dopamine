//
//  DOMainViewController.m
//  Dopamine
//

#import "DOMainViewController.h"
#import "DOUIManager.h"
#import "DOEnvironmentManager.h"
#import "DOJailbreaker.h"
#import "DOExploitManager.h"
#import <libjailbreak/libjailbreak.h>
#import <libjailbreak/jbclient_xpc.h>
#import <unistd.h>
#import <dlfcn.h>
#import <string.h>
#import <errno.h>
#import <fcntl.h>
#import <signal.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface DOMiniLogView : UIView
@property (nonatomic, strong) UITextView *textView;
@end

@implementation DOMiniLogView

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
        self.layer.cornerRadius = 10;
        self.clipsToBounds = YES;

        _textView = [[UITextView alloc] init];
        _textView.translatesAutoresizingMaskIntoConstraints = NO;
        _textView.backgroundColor = [UIColor clearColor];
        _textView.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
        _textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
        _textView.editable = NO;
        _textView.selectable = YES;
        _textView.scrollEnabled = YES;
        _textView.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
        [self addSubview:_textView];

        [NSLayoutConstraint activateConstraints:@[
            [_textView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_textView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_textView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_textView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        ]];
    }
    return self;
}

- (void)showLog:(NSString *)log
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showLog:log];
        });
        return;
    }

    NSString *line = [NSString stringWithFormat:@"> %@\n", log];
    self.textView.text = [self.textView.text stringByAppendingString:line];
    [UIView performWithoutAnimation:^{
        [self.textView scrollRangeToVisible:NSMakeRange(self.textView.text.length, 0)];
    }];
}

@end

@interface MiniHookChoice : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy) NSString *value;
@property (nonatomic, copy) NSData *fileData;
+ (instancetype)choiceWithTitle:(NSString *)title detail:(NSString *)detail value:(NSString *)value;
@end

@implementation MiniHookChoice
+ (instancetype)choiceWithTitle:(NSString *)title detail:(NSString *)detail value:(NSString *)value
{
    MiniHookChoice *item = [[MiniHookChoice alloc] init];
    item.title = title;
    item.detail = detail;
    item.value = value;
    return item;
}
@end

@interface MiniHookPickerViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate>
@property (nonatomic, copy) NSArray<MiniHookChoice *> *apps;
@property (nonatomic, copy) void (^onAdd)(MiniHookChoice *app, MiniHookChoice *dylib);
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIButton *confirmButton;
@property (nonatomic, strong) MiniHookChoice *selectedApp;
@property (nonatomic, strong) MiniHookChoice *selectedDylib;
@end

@implementation MiniHookPickerViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1.0];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Add Hook";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    [self.view addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"Close" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor colorWithWhite:0.75 alpha:1.0] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self.view addSubview:self.tableView];

    self.confirmButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.confirmButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.confirmButton setTitle:@"Add" forState:UIControlStateNormal];
    [self.confirmButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.confirmButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.confirmButton.backgroundColor = [UIColor systemBlueColor];
    self.confirmButton.layer.cornerRadius = 12;
    [self.confirmButton addTarget:self action:@selector(confirmTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.confirmButton];
    [self refreshConfirmButton];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [title.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [close.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [close.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],

        [self.tableView.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.confirmButton.topAnchor constant:-12],

        [self.confirmButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [self.confirmButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [self.confirmButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
        [self.confirmButton.heightAnchor constraintEqualToConstant:50],
    ]];
}

- (void)refreshConfirmButton
{
    BOOL ready = (self.selectedApp != nil && self.selectedDylib != nil);
    self.confirmButton.enabled = ready;
    self.confirmButton.alpha = ready ? 1.0 : 0.45;
}

- (void)closeTapped
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)confirmTapped
{
    if (!self.selectedApp || !self.selectedDylib || !self.onAdd) return;
    void (^onAdd)(MiniHookChoice *, MiniHookChoice *) = self.onAdd;
    MiniHookChoice *app = self.selectedApp;
    MiniHookChoice *dylib = self.selectedDylib;
    [self dismissViewControllerAnimated:YES completion:^{
        onAdd(app, dylib);
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return MAX((NSInteger)self.apps.count, 1);
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return (section == 0) ? @"App" : @"Dylib";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 1) return @"Upload a .dylib from Files / iCloud Drive";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
    }
    cell.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    if (indexPath.section == 0) {
        if (self.apps.count == 0) {
            cell.textLabel.text = @"No apps found";
            cell.detailTextLabel.text = nil;
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        MiniHookChoice *item = self.apps[indexPath.row];
        cell.textLabel.text = item.title;
        cell.detailTextLabel.text = item.detail;
        cell.accessoryType = ([self.selectedApp.value isEqualToString:item.value]) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        return cell;
    }

    if (self.selectedDylib) {
        cell.textLabel.text = self.selectedDylib.title;
        cell.detailTextLabel.text = @"Tap to replace";
    } else {
        cell.textLabel.text = @"Upload dylib…";
        cell.detailTextLabel.text = @"Choose a .dylib file";
    }
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        if (indexPath.row >= (NSInteger)self.apps.count) return;
        self.selectedApp = self.apps[indexPath.row];
        [self refreshConfirmButton];
        [tableView reloadData];
        return;
    }
    [self presentDylibPicker];
}

- (void)presentDylibPicker
{
    // .dylib is com.apple.mach-o-dylib → public.unix-executable, NOT public.data.
    // asCopy:YES greys those out because Files will not "import" executables.
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    NSArray<NSString *> *ids = @[
        @"com.apple.mach-o-dylib",
        @"public.unix-executable",
        @"public.executable",
        @"com.apple.mach-o-binary",
        @"public.item",
        @"public.data",
        @"public.content",
        @"public.archive",
    ];
    for (NSString *ident in ids) {
        UTType *type = [UTType typeWithIdentifier:ident];
        if (type) [types addObject:type];
    }
    UTType *byExt = [UTType typeWithFilenameExtension:@"dylib"];
    if (byExt) [types insertObject:byExt atIndex:0];

    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:NO];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.shouldShowFileExtensions = YES;
    picker.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url = urls.firstObject;
    if (!url) return;

    NSString *name = url.lastPathComponent ?: @"hook.dylib";
    if (![name.pathExtension.lowercaseString isEqualToString:@"dylib"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Need a dylib"
                                                                       message:@"Pick a file with the .dylib extension."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    BOOL accessing = [url startAccessingSecurityScopedResource];
    __block NSData *data = nil;
    __block NSError *readError = nil;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingWithoutChanges error:&readError byAccessor:^(NSURL *newURL) {
        data = [NSData dataWithContentsOfURL:newURL options:NSDataReadingUncached error:&readError];
    }];
    if (!data.length) {
        data = [NSData dataWithContentsOfURL:url options:NSDataReadingUncached error:&readError];
    }
    if (accessing) [url stopAccessingSecurityScopedResource];

    if (!data.length) {
        NSString *message = readError.localizedDescription ?: @"Could not read the selected file.";
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Import failed"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    MiniHookChoice *dylib = [MiniHookChoice choiceWithTitle:name detail:name value:name];
    dylib.fileData = data;
    self.selectedDylib = dylib;
    [self refreshConfirmButton];
    [self.tableView reloadData];
}

@end

static BOOL MiniWriteDataToPath(NSData *data, NSString *path, NSString **errorOut)
{
    if (!data || !path.length) {
        if (errorOut) *errorOut = @"no data";
        return NO;
    }

    NSString *dir = path.stringByDeletingLastPathComponent;
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755} error:nil];
    chmod(dir.fileSystemRepresentation, 0755);

    const char *cpath = path.fileSystemRepresentation;
    int fd = open(cpath, O_WRONLY | O_CREAT | O_TRUNC, 0755);
    if (fd < 0) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"open %s: %s", cpath, strerror(errno)];
        return NO;
    }

    const uint8_t *bytes = data.bytes;
    NSUInteger left = data.length;
    while (left > 0) {
        ssize_t n = write(fd, bytes, left);
        if (n < 0) {
            int e = errno;
            close(fd);
            if (errorOut) *errorOut = [NSString stringWithFormat:@"write %s: %s", cpath, strerror(e)];
            return NO;
        }
        bytes += n;
        left -= (NSUInteger)n;
    }
    fchmod(fd, 0755);
    close(fd);
    return YES;
}

static void MiniWithKernelCred(void (^block)(void))
{
    uint64_t credBackup = 0;
    int steal = jbclient_root_steal_ucred(0, &credBackup);
    uint64_t orgLabel = 0;
    int mac = jbclient_root_set_mac_label(1, (uint64_t)-1, &orgLabel);
    block();
    if (steal == 0 && credBackup) {
        jbclient_root_steal_ucred(credBackup, NULL);
    }
    (void)mac;
}

@interface DOMainViewController ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIButton *executeButton;
@property (nonatomic, strong) UIButton *checkEnvButton;
@property (nonatomic, strong) UIButton *clearEnvButton;
@property (nonatomic, strong) UIButton *addHookButton;
@property (nonatomic, strong) DOMiniLogView *logView;
@property (nonatomic) BOOL running;
@end

@implementation DOMainViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self setupUI];

    __weak typeof(self) weakSelf = self;
    [DOUIManager sharedInstance].logHandler = ^(NSString *log) {
        [weakSelf.logView showLog:log];
    };
    [[DOUIManager sharedInstance] startLogCapture];

    [self refreshSubtitle];
    [self refreshAddHookButton];
    [self appendLog:[NSString stringWithFormat:@"Mini Dopamine ready. uid=%d", getuid()]];
}

- (void)refreshSubtitle
{
    DOExploitManager *exploitManager = [DOExploitManager sharedManager];
    DOEnvironmentManager *environment = [DOEnvironmentManager sharedManager];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:environment.versionSupportString];

    DOExploit *kernelExploit = exploitManager.selectedKernelExploit;
    [lines addObject:[NSString stringWithFormat:@"kernel: %@", kernelExploit ? kernelExploit.name : @"ClearSword (missing)"]];

    if (environment.isPACBypassRequired) {
        DOExploit *pacBypass = exploitManager.selectedPACBypass;
        [lines addObject:[NSString stringWithFormat:@"pac: %@", pacBypass ? pacBypass.name : @"missing"]];
    }

    if (environment.isPPLBypassRequired) {
        DOExploit *pplBypass = exploitManager.selectedPPLBypass;
        NSString *kind = environment.isSPTM ? @"sptm" : @"ppl";
        [lines addObject:[NSString stringWithFormat:@"%@: %@", kind, pplBypass ? pplBypass.name : @"missing"]];
    }

    if (!environment.isSupported) {
        [lines addObject:@"warning: device may be unsupported"];
    }

    self.subtitleLabel.text = [lines componentsJoinedByString:@"\n"];
}

- (UIStatusBarStyle)preferredStatusBarStyle
{
    return UIStatusBarStyleLightContent;
}

- (UIButton *)makeSecondaryButtonTitle:(NSString *)title action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    button.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1.0];
    button.layer.cornerRadius = 12;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)setupUI
{
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.text = @"Mini Dopamine";
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    [self.view addSubview:self.titleLabel];

    self.subtitleLabel = [[UILabel alloc] init];
    self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.subtitleLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    self.subtitleLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.subtitleLabel.numberOfLines = 0;
    [self.view addSubview:self.subtitleLabel];

    self.executeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.executeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.executeButton setTitle:@"Execute" forState:UIControlStateNormal];
    [self.executeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.executeButton.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    self.executeButton.backgroundColor = [UIColor systemBlueColor];
    self.executeButton.layer.cornerRadius = 12;
    [self.executeButton addTarget:self action:@selector(executeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.executeButton];

    self.checkEnvButton = [self makeSecondaryButtonTitle:@"Check Env" action:@selector(checkEnvTapped)];
    [self.view addSubview:self.checkEnvButton];
    self.clearEnvButton = [self makeSecondaryButtonTitle:@"Clear Env" action:@selector(clearEnvTapped)];
    self.clearEnvButton.backgroundColor = [UIColor systemRedColor];
    [self.view addSubview:self.clearEnvButton];

    self.addHookButton = [self makeSecondaryButtonTitle:@"Add Hook" action:@selector(addHookTapped)];
    [self.view addSubview:self.addHookButton];

    self.logView = [[DOMiniLogView alloc] init];
    self.logView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.logView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.titleLabel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:20],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],

        [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:8],
        [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],

        [self.executeButton.topAnchor constraintEqualToAnchor:self.subtitleLabel.bottomAnchor constant:20],
        [self.executeButton.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.executeButton.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],
        [self.executeButton.heightAnchor constraintEqualToConstant:50],

        [self.checkEnvButton.topAnchor constraintEqualToAnchor:self.executeButton.bottomAnchor constant:10],
        [self.checkEnvButton.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.checkEnvButton.trailingAnchor constraintEqualToAnchor:self.clearEnvButton.leadingAnchor constant:-10],
        [self.checkEnvButton.heightAnchor constraintEqualToConstant:44],
        [self.checkEnvButton.widthAnchor constraintEqualToAnchor:self.clearEnvButton.widthAnchor],

        [self.clearEnvButton.topAnchor constraintEqualToAnchor:self.checkEnvButton.topAnchor],
        [self.clearEnvButton.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],
        [self.clearEnvButton.heightAnchor constraintEqualToAnchor:self.checkEnvButton.heightAnchor],

        [self.addHookButton.topAnchor constraintEqualToAnchor:self.checkEnvButton.bottomAnchor constant:10],
        [self.addHookButton.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.addHookButton.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],
        [self.addHookButton.heightAnchor constraintEqualToConstant:44],

        [self.logView.topAnchor constraintEqualToAnchor:self.addHookButton.bottomAnchor constant:16],
        [self.logView.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.logView.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],
        [self.logView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
    ]];
}

- (void)appendLog:(NSString *)log
{
    [[DOUIManager sharedInstance] sendLog:log];
}

- (void)updateButtonTitle:(NSString *)title color:(UIColor *)color enabled:(BOOL)enabled
{
    self.executeButton.enabled = enabled;
    self.executeButton.alpha = enabled ? 1.0 : 0.85;
    [self.executeButton setTitle:title forState:UIControlStateNormal];
    self.executeButton.backgroundColor = color;
}

- (void)setRunning:(BOOL)running
{
    _running = running;
    if (running) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateButtonTitle:@"Running..." color:[UIColor systemGrayColor] enabled:NO];
        });
    }
}

- (void)consumeSandboxExtensions:(char *)sandboxExtensions
{
    if (!sandboxExtensions || sandboxExtensions[0] == '\0') return;
    int64_t (*sandbox_extension_consume)(const char *) = dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    if (!sandbox_extension_consume) {
        [self appendLog:@"sandbox_extension_consume missing"];
        return;
    }
    char *it = sandboxExtensions;
    char *last = sandboxExtensions;
    while (*(++it) != '\0') {
        if (*it == '|') {
            *it = '\0';
            sandbox_extension_consume(last);
            last = &it[1];
            *it = '|';
        }
    }
    sandbox_extension_consume(last);
}

- (BOOL)jailbrokenCheckinRoot:(char **)rootPathOut
{
    char *rootPath = NULL;
    char *bootUUID = NULL;
    char *sandboxExtensions = NULL;
    bool fullyDebugged = false;
    bool forceCSAdhoc = false;
    int checkin = jbclient_process_checkin(&rootPath, &bootUUID, &sandboxExtensions, &fullyDebugged, &forceCSAdhoc);
    if (sandboxExtensions) {
        [self consumeSandboxExtensions:sandboxExtensions];
        free(sandboxExtensions);
    }
    if (bootUUID) free(bootUUID);
    if (checkin != 0 || !rootPath || !rootPath[0]) {
        if (rootPath) free(rootPath);
        if (rootPathOut) *rootPathOut = NULL;
        return NO;
    }
    if (rootPathOut) *rootPathOut = rootPath;
    else free(rootPath);
    return YES;
}

- (void)refreshAddHookButton
{
    BOOL jailbroken = [self jailbrokenCheckinRoot:NULL];
    self.addHookButton.enabled = jailbroken;
    self.addHookButton.alpha = jailbroken ? 1.0 : 0.45;
}

- (NSArray<MiniHookChoice *> *)collectApps
{
    NSMutableArray<MiniHookChoice *> *apps = [NSMutableArray array];
    [apps addObject:[MiniHookChoice choiceWithTitle:@"SpringBoard" detail:@"com.apple.springboard" value:@"com.apple.springboard"]];

    NSString *bundleRoot = @"/var/containers/Bundle/Application";
    NSArray<NSString *> *uuids = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bundleRoot error:nil];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithObject:@"com.apple.springboard"];
    for (NSString *uuid in uuids) {
        NSString *uuidPath = [bundleRoot stringByAppendingPathComponent:uuid];
        NSArray<NSString *> *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:uuidPath error:nil];
        for (NSString *item in items) {
            if (![item.pathExtension isEqualToString:@"app"]) continue;
            NSString *appPath = [uuidPath stringByAppendingPathComponent:item];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Info.plist"]];
            NSString *bundleId = info[@"CFBundleIdentifier"];
            if (!bundleId.length || [seen containsObject:bundleId]) continue;
            [seen addObject:bundleId];
            NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: item.stringByDeletingPathExtension;
            [apps addObject:[MiniHookChoice choiceWithTitle:name detail:bundleId value:bundleId]];
        }
    }
    return apps;
}

- (BOOL)writeHookForBundleId:(NSString *)bundleId dylibEntry:(NSString *)dylibEntry plistPath:(NSString *)plistPath
{
    NSMutableDictionary *hooks = [[NSMutableDictionary alloc] initWithContentsOfFile:plistPath];
    if (!hooks) hooks = [NSMutableDictionary dictionary];

    id existing = hooks[bundleId];
    NSMutableArray<NSString *> *libs = nil;
    if ([existing isKindOfClass:[NSArray class]]) {
        libs = [existing mutableCopy];
    } else if ([existing isKindOfClass:[NSString class]]) {
        libs = [NSMutableArray arrayWithObject:existing];
    } else {
        libs = [NSMutableArray array];
    }
    if (![libs containsObject:dylibEntry]) {
        [libs addObject:dylibEntry];
    }
    hooks[bundleId] = libs;

    NSError *plistError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:hooks format:NSPropertyListBinaryFormat_v1_0 options:0 error:&plistError];
    if (!data) {
        [self appendLog:[NSString stringWithFormat:@"Add Hook: serialize failed: %@", plistError.localizedDescription]];
        return NO;
    }
    if (![data writeToFile:plistPath atomically:NO]) {
        [self appendLog:[NSString stringWithFormat:@"Add Hook: write failed: %s: %@", plistPath.fileSystemRepresentation, [NSString stringWithUTF8String:strerror(errno)] ?: @"unknown"]];
        return NO;
    }
    chmod(plistPath.fileSystemRepresentation, 0666);
    return YES;
}

- (void)withEnvPrivileges:(void (^)(void))block
{
    char *rootPath = NULL;
    BOOL jailbroken = [self jailbrokenCheckinRoot:&rootPath];
    uint64_t credBackup = 0;
    int steal = -1;
    if (jailbroken) {
        if (rootPath) {
            if (gSystemInfo.jailbreakInfo.rootPath) free(gSystemInfo.jailbreakInfo.rootPath);
            gSystemInfo.jailbreakInfo.rootPath = strdup(rootPath);
        }
        jbclient_dopamine_get_root();
        steal = jbclient_root_steal_ucred(0, &credBackup);
        uint64_t orgLabel = 0;
        jbclient_root_set_mac_label(1, (uint64_t)-1, &orgLabel);
    }
    block();
    if (steal == 0 && credBackup) {
        jbclient_root_steal_ucred(credBackup, NULL);
    }
    if (jailbroken) {
        jbclient_dopamine_drop_root();
        free(rootPath);
    }
}

- (void)checkEnvTapped
{
    [self appendLog:@"--- Check Env ---"];
    [self withEnvPrivileges:^{
        [[[DOJailbreaker alloc] init] logMiniEnvironment];
    }];
}

- (void)clearEnvTapped
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear Env"
                                                                   message:@"Unmount fakelib and delete leftover Mini jbroot. Does not reboot the device."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self appendLog:@"--- Clear Env ---"];
        [self withEnvPrivileges:^{
            NSError *error = [[[DOJailbreaker alloc] init] clearMiniEnvironment];
            if (error) {
                [self appendLog:[NSString stringWithFormat:@"Clear Env: %@", error.localizedDescription]];
            } else {
                [self appendLog:@"Clear Env: done"];
            }
        }];
        [self refreshAddHookButton];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)addHookTapped
{
    char *rootPath = NULL;
    if (![self jailbrokenCheckinRoot:&rootPath]) {
        [self appendLog:@"Add Hook: not jailbroken (Execute first)"];
        [self refreshAddHookButton];
        return;
    }

    jbclient_dopamine_get_root();
    NSArray<MiniHookChoice *> *apps = [self collectApps];
    jbclient_dopamine_drop_root();
    free(rootPath);

    MiniHookPickerViewController *picker = [[MiniHookPickerViewController alloc] init];
    picker.apps = apps;
    __weak typeof(self) weakSelf = self;
    picker.onAdd = ^(MiniHookChoice *app, MiniHookChoice *dylib) {
        [weakSelf confirmHookApp:app dylib:dylib];
    };
    picker.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)confirmHookApp:(MiniHookChoice *)app dylib:(MiniHookChoice *)dylib
{
    char *rootPath = NULL;
    if (![self jailbrokenCheckinRoot:&rootPath]) {
        [self appendLog:@"Add Hook: not jailbroken"];
        return;
    }
    jbclient_dopamine_get_root();
    NSString *root = [NSString stringWithUTF8String:rootPath];

    NSString *fileName = dylib.title.length ? dylib.title : dylib.value.lastPathComponent;
    if (![fileName.pathExtension.lowercaseString isEqualToString:@"dylib"]) {
        fileName = [fileName stringByAppendingPathExtension:@"dylib"];
    }
    if (!dylib.fileData.length) {
        [self appendLog:@"Add Hook: no dylib data (re-pick the file)"];
        jbclient_dopamine_drop_root();
        free(rootPath);
        return;
    }

    // Prefer jbroot/var/mobile: check-in already issues a read-write sandbox
    // extension there. Fall back to basebin/hooks with kernel creds.
    NSString *mobileDest = [[root stringByAppendingPathComponent:@"var/mobile/hooks"] stringByAppendingPathComponent:fileName];
    NSString *baseDest = [[root stringByAppendingPathComponent:@"basebin/hooks"] stringByAppendingPathComponent:fileName];
    NSString *mobilePlist = [root stringByAppendingPathComponent:@"var/mobile/hooks.plist"];
    NSString *basePlist = [root stringByAppendingPathComponent:@"basebin/hooks.plist"];
    __block NSString *writeError = nil;
    __block BOOL wroteMobile = MiniWriteDataToPath(dylib.fileData, mobileDest, &writeError);
    __block BOOL wroteBase = NO;
    __block BOOL ok = NO;
    __block NSString *entry = nil;

    MiniWithKernelCred(^{
        if (!wroteMobile) {
            wroteMobile = MiniWriteDataToPath(dylib.fileData, mobileDest, &writeError);
        }
        wroteBase = MiniWriteDataToPath(dylib.fileData, baseDest, &writeError);
        if (!wroteMobile && !wroteBase) return;

        entry = wroteMobile
            ? [@"/var/mobile/hooks/" stringByAppendingString:fileName]
            : [@"/basebin/hooks/" stringByAppendingString:fileName];
        if (wroteMobile) {
            ok = [self writeHookForBundleId:app.value dylibEntry:entry plistPath:mobilePlist];
        }
        if (wroteBase) {
            BOOL baseOk = [self writeHookForBundleId:app.value dylibEntry:entry plistPath:basePlist];
            ok = ok || baseOk;
        }
    });

    if (!wroteMobile && !wroteBase) {
        [self appendLog:[NSString stringWithFormat:@"Add Hook: write failed: %@", writeError ?: @"unknown"]];
        jbclient_dopamine_drop_root();
        free(rootPath);
        return;
    }
    if (!ok) {
        jbclient_dopamine_drop_root();
        free(rootPath);
        return;
    }

    [self appendLog:[NSString stringWithFormat:@"Add Hook: %@ -> %@", app.value, entry]];
    if ([app.value isEqualToString:@"com.apple.springboard"]) {
        [self appendLog:@"respringing SpringBoard to load the hook"];
        MiniWithKernelCred(^{
            NSString *jbctl = [root stringByAppendingPathComponent:@"basebin/jbctl"];
            if (access(jbctl.fileSystemRepresentation, X_OK) == 0) {
                exec_cmd(jbctl.fileSystemRepresentation, "respring", NULL);
            } else {
                killall("/usr/libexec/backboardd", SIGTERM);
            }
        });
    } else {
        [self appendLog:@"relaunch that app to load it"];
    }
    jbclient_dopamine_drop_root();
    free(rootPath);
}

- (void)executeTapped
{
    if (self.running) return;
    [self setRunning:YES];

    DOJailbreaker *jailbreaker = [[DOJailbreaker alloc] init];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        if ([jailbreaker contiguousMappingWorkaroundNeeded]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self presentContiguousMappingAlert:jailbreaker];
            });
            return;
        }
        [self runMini:jailbreaker];
    });
}

- (void)presentContiguousMappingAlert:(DOJailbreaker *)jailbreaker
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Respring Required"
                                                                   message:@"ClearSword needs a contiguous mapping. Apply the workaround, then reopen Mini Dopamine and tap Execute again."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        self.running = NO;
        [self updateButtonTitle:@"Execute" color:[UIColor systemBlueColor] enabled:YES];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Apply Workaround" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self appendLog:@"Applying contiguous mapping workaround..."];
        [jailbreaker applyContiguousMappingWorkaround];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)runMini:(DOJailbreaker *)jailbreaker
{
    NSError *error = nil;
    [jailbreaker runMiniWithError:&error];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (error) {
            [self appendLog:[NSString stringWithFormat:@"Failed: %@", error.localizedDescription]];
            _running = NO;
            [self updateButtonTitle:@"Retry" color:[UIColor systemOrangeColor] enabled:YES];
        }
        else {
            [self appendLog:@"Done."];
            _running = YES;
            [self updateButtonTitle:@"Done" color:[UIColor systemGreenColor] enabled:NO];
            [self refreshAddHookButton];
        }
    });
}

@end
