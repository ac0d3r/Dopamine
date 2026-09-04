//
//  Jailbreaker.h
//  Dopamine
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DOJailbreaker : NSObject

- (void)runMiniWithError:(NSError **)errOut;

- (BOOL)contiguousMappingWorkaroundNeeded;
- (void)applyContiguousMappingWorkaround;

@end

NS_ASSUME_NONNULL_END
