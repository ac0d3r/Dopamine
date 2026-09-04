//
//  DOUIManager.m
//  Dopamine
//

#import "DOUIManager.h"
#import <unistd.h>

@implementation DOUIManager

+ (instancetype)sharedInstance
{
    static DOUIManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[DOUIManager alloc] init];
    });
    return sharedInstance;
}

- (id)init
{
    if (self = [super init]) {
        _logRecord = [NSMutableArray new];
        _logLock = [NSLock new];
    }
    return self;
}

- (void)sendLog:(NSString *)log debug:(BOOL)debug
{
    (void)debug;
    if (!self.logView || !log) return;

    [_logLock lock];
    [self.logRecord addObject:log];
    [self.logView showLog:log];
    [_logLock unlock];
}

- (void)completeJailbreak
{
    [self.logView didComplete];
}

- (void)observeFileDescriptor:(int)fd withCallback:(void (^)(char *line))callbackBlock
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int stdout_pipe[2];
        int stdout_orig[2];
        if (pipe(stdout_pipe) != 0 || pipe(stdout_orig) != 0) {
            return;
        }

        dup2(fd, stdout_orig[1]);
        close(stdout_orig[0]);

        dup2(stdout_pipe[1], fd);
        close(stdout_pipe[1]);

        char cur = 0;
        char line[1024];
        int line_index = 0;
        ssize_t bytes_read;

        while ((bytes_read = read(stdout_pipe[0], &cur, sizeof(cur))) > 0) {
            @autoreleasepool {
                write(stdout_orig[1], &cur, bytes_read);

                if (cur == '\n') {
                    line[line_index] = '\0';
                    callbackBlock(line);
                    line_index = 0;
                } else if (line_index < (int)sizeof(line) - 1) {
                    line[line_index++] = cur;
                }
            }
        }
        close(stdout_pipe[0]);
    });
}

- (void)startLogCapture
{
    [self observeFileDescriptor:STDOUT_FILENO withCallback:^(char *line) {
        [self sendLog:[NSString stringWithUTF8String:line] debug:YES];
    }];
    [self observeFileDescriptor:STDERR_FILENO withCallback:^(char *line) {
        [self sendLog:[NSString stringWithUTF8String:line] debug:YES];
    }];
}

@end
