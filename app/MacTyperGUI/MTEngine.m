#import "MTEngine.h"
#import "libmactyper.h"

@interface MTEngine ()
@property (nonatomic, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, readwrite, getter=isPaused) BOOL paused;
@property (nonatomic, readwrite, getter=isStopping) BOOL stopping;
/// 任务执行期间保持自身存活，保证引擎回调时 ctx 有效。
@property (nonatomic, strong, nullable) MTEngine *retainedWhileRunning;
- (void)handleEvent:(int)kind a:(long long)a b:(long long)b message:(nullable NSString *)message;
@end

// 在引擎线程上调用，转到主线程处理；同一线程按顺序派发，主线程收到的顺序不变。
static void MTEngineCallback(void *ctx, int kind, long long a, long long b, const char *message) {
    @autoreleasepool {
        MTEngine *engine = (__bridge MTEngine *)ctx;
        NSString *text = message ? [NSString stringWithUTF8String:message] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            [engine handleEvent:kind a:a b:b message:text];
        });
    }
}

@implementation MTEngine

- (BOOL)startWithText:(NSString *)text typoPath:(NSString *)typoPath config:(MTConfig)config error:(NSString **)error {
    if (self.running) {
        if (error) *error = @"已有任务在执行";
        return NO;
    }
    const char *path = typoPath.length ? typoPath.fileSystemRepresentation : NULL;
    char *failure = MTStart((char *)text.UTF8String, (char *)path, config, MTEngineCallback, (__bridge void *)self);
    if (failure) {
        if (error) *error = [NSString stringWithUTF8String:failure] ?: @"启动失败";
        MTFreeString(failure);
        return NO;
    }
    self.running = YES;
    self.paused = NO;
    self.stopping = NO;
    self.retainedWhileRunning = self;
    return YES;
}

- (BOOL)setPaused:(BOOL)paused {
    if (!self.running || self.stopping) return NO;
    if (MTSetPaused(paused ? 1 : 0) == 0) return NO;
    self.paused = paused;
    return YES;
}

- (BOOL)stop {
    if (!self.running) return NO;
    self.stopping = YES;
    self.paused = NO;
    MTStop();
    return YES;
}

- (void)handleEvent:(int)kind a:(long long)a b:(long long)b message:(NSString *)message {
    switch (kind) {
    case MT_EVENT_COUNTDOWN:
        [self.delegate engineDidCountdown:(NSInteger)a];
        break;
    case MT_EVENT_PROGRESS:
        [self.delegate engineDidProgress:(NSInteger)a total:(NSInteger)b];
        break;
    case MT_EVENT_FINISHED:
        self.running = NO;
        self.paused = NO;
        self.stopping = NO;
        [self.delegate engineDidFinish:(MTFinishReason)a message:message];
        self.retainedWhileRunning = nil;
        break;
    }
}

@end
