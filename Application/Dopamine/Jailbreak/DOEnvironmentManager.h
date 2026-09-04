//
//  EnvironmentManager.h
//  Dopamine
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DOEnvironmentManager : NSObject

+ (instancetype)sharedManager;

- (NSString *)systemVersion;
- (NSString *)versionSupportString;

- (BOOL)isSupported;
- (BOOL)isArm64e;
- (BOOL)isSPTM;
- (BOOL)isInstalledThroughTrollStore;
- (BOOL)isPACBypassRequired;
- (BOOL)isPPLBypassRequired;

- (NSString *)accessibleKernelPath;
- (nullable NSString *)accessibleSPTMPath;
- (nullable NSString *)accessibleTXMPath;

@end

NS_ASSUME_NONNULL_END
