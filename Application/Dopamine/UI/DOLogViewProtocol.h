//
//  DOLogViewProtocol.h
//  Dopamine
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol DOLogViewProtocol <NSObject>

- (void)showLog:(NSString *)log;
- (void)didComplete;

@optional
- (void)updateLog:(NSString *)log;

@end

NS_ASSUME_NONNULL_END
