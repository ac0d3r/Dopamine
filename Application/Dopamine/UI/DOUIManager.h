//
//  DOUIManager.h
//  Dopamine
//

#import <Foundation/Foundation.h>
#import "DOLogViewProtocol.h"

NS_ASSUME_NONNULL_BEGIN

@interface DOUIManager : NSObject
{
    NSLock *_logLock;
}

@property (nonatomic, retain) NSObject<DOLogViewProtocol> *logView;
@property (atomic, retain) NSMutableArray<NSString *> *logRecord;

+ (instancetype)sharedInstance;

- (void)sendLog:(NSString *)log debug:(BOOL)debug;
- (void)completeJailbreak;
- (void)startLogCapture;

@end

NS_ASSUME_NONNULL_END
