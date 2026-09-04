//
//  DONavigationController.m
//  Dopamine
//

#import "DONavigationController.h"

@interface DONavigationController ()
@property (nonatomic) DOMainViewController *mainView;
@end

@implementation DONavigationController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    [self setNavigationBarHidden:YES];
    [self setOverrideUserInterfaceStyle:UIUserInterfaceStyleDark];
    [self pushViewController:(self.mainView = [[DOMainViewController alloc] init]) animated:NO];
}

@end
