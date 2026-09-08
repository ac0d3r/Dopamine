//
//  DOUIManager.h
//  Dopamine
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DOUIManager : NSObject

@property (nonatomic, copy, nullable) void (^logHandler)(NSString *log);

+ (instancetype)sharedInstance;

- (void)sendLog:(NSString *)log;
- (void)startLogCapture;

@end

NS_ASSUME_NONNULL_END
