//
//  DOMainViewController.m
//  Dopamine
//

#import "DOMainViewController.h"
#import "DOUIManager.h"
#import "DOEnvironmentManager.h"
#import "DOJailbreaker.h"
#import "DOExploitManager.h"
#import "DOLogViewProtocol.h"
#import <libjailbreak/libjailbreak.h>
#import <unistd.h>

@interface DOMiniLogView : UIView <DOLogViewProtocol>
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

- (void)didComplete
{
}

@end

@interface DOMainViewController ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIButton *executeButton;
@property (nonatomic, strong) DOMiniLogView *logView;
@property (nonatomic) BOOL running;
@end

@implementation DOMainViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    [self setupUI];

    [DOUIManager sharedInstance].logView = self.logView;
    [[DOUIManager sharedInstance] startLogCapture];

    [self refreshSubtitle];
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

        [self.logView.topAnchor constraintEqualToAnchor:self.executeButton.bottomAnchor constant:16],
        [self.logView.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.logView.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],
        [self.logView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
    ]];
}

- (void)appendLog:(NSString *)log
{
    [[DOUIManager sharedInstance] sendLog:log debug:NO];
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
            [[DOUIManager sharedInstance] completeJailbreak];
        }
    });
}

@end
