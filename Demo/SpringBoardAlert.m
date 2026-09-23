#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <string.h>
#import <limits.h>

static const CGFloat kChipHeight = 40.0;
static const CGFloat kChipWidth = 220.0;

static UIWindow *gOverlayWindow = nil;

static BOOL isSpringBoard(void)
{
    char path[PATH_MAX];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) return NO;
    return strstr(path, "SpringBoard") != NULL;
}

static UIWindowScene *activeWindowScene(void)
{
    UIWindowScene *fallback = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return windowScene;
        }
        if (!fallback) fallback = windowScene;
    }
    return fallback;
}

static void dismissOverlay(void)
{
    gOverlayWindow.hidden = YES;
    gOverlayWindow.rootViewController = nil;
    gOverlayWindow = nil;
}

@interface MiniChipController : UIViewController
@end

@implementation MiniChipController
- (void)closeTapped
{
    dismissOverlay();
}

- (void)chipTapped
{
    if (self.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Mini Dopamine"
                                                                   message:@"SpringBoard hooked"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        dismissOverlay();
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

static void installOverlay(int attempt)
{
    if (gOverlayWindow) return;

    UIWindowScene *scene = activeWindowScene();
    if (!scene) {
        if (attempt < 40) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                installOverlay(attempt + 1);
            });
        }
        return;
    }

    CGRect screen = scene.coordinateSpace.bounds;
    if (screen.size.width < 2 || screen.size.height < 2) {
        screen = [UIScreen mainScreen].bounds;
    }
    CGFloat top = 54.0;
    if (scene.windows.firstObject.safeAreaInsets.top > 20) {
        top = scene.windows.firstObject.safeAreaInsets.top + 4.0;
    }
    CGRect frame = CGRectMake((screen.size.width - kChipWidth) / 2.0, top, kChipWidth, kChipHeight);

    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.frame = frame;
    window.windowLevel = UIWindowLevelStatusBar + 1;
    window.backgroundColor = [UIColor clearColor];
    window.opaque = NO;
    window.clipsToBounds = YES;

    MiniChipController *root = [MiniChipController new];
    root.view.frame = CGRectMake(0, 0, kChipWidth, kChipHeight);
    root.view.backgroundColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.35 alpha:0.94];
    root.view.layer.cornerRadius = kChipHeight / 2.0;
    root.view.clipsToBounds = YES;

    UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
    chip.frame = CGRectMake(12, 0, kChipWidth - 52, kChipHeight);
    [chip setTitle:@"Mini Dopamine" forState:UIControlStateNormal];
    [chip setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    chip.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightBold];
    chip.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [chip addTarget:root action:@selector(chipTapped) forControlEvents:UIControlEventTouchUpInside];
    [root.view addSubview:chip];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(kChipWidth - 40, 0, 40, kChipHeight);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightBold];
    [close addTarget:root action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [root.view addSubview:close];

    window.rootViewController = root;
    window.hidden = NO;
    gOverlayWindow = window;
}

static void (*SpringBoard_applicationDidFinishLaunching)(id, SEL, id) = NULL;
static void Mini_applicationDidFinishLaunching(id self, SEL _cmd, id arg)
{
    if (SpringBoard_applicationDidFinishLaunching) {
        SpringBoard_applicationDidFinishLaunching(self, _cmd, arg);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        installOverlay(0);
    });
}

static void swizzleSpringBoardLaunch(void)
{
    Class cls = NSClassFromString(@"SpringBoard");
    if (!cls) return;
    SEL sel = @selector(applicationDidFinishLaunching:);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    SpringBoard_applicationDidFinishLaunching = (void (*)(id, SEL, id))method_getImplementation(method);
    method_setImplementation(method, (IMP)Mini_applicationDidFinishLaunching);
}

__attribute__((constructor))
static void SpringBoardAlertCtor(void)
{
    if (!isSpringBoard()) return;
    swizzleSpringBoardLaunch();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        installOverlay(0);
    });
}
