#import <Foundation/Foundation.h>
#import "engine_bridge.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MTFinishReason) {
    MTFinishReasonDone = MT_FINISH_DONE,
    MTFinishReasonStopped = MT_FINISH_STOPPED,
    MTFinishReasonError = MT_FINISH_ERROR,
};

/// 回调都在主线程调用。
@protocol MTEngineDelegate <NSObject>
- (void)engineDidCountdown:(NSInteger)seconds;
- (void)engineDidProgress:(NSInteger)done total:(NSInteger)total;
- (void)engineDidFinish:(MTFinishReason)reason message:(nullable NSString *)message;
@end

/// Go 打字引擎（静态库）的封装。只能在主线程调用。
@interface MTEngine : NSObject
@property (nonatomic, weak, nullable) id<MTEngineDelegate> delegate;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly, getter=isPaused) BOOL paused;
@property (nonatomic, readonly, getter=isStopping) BOOL stopping;

/// 校验并开始任务。参数、正文或错词库无效时返回 NO，不会发送任何按键。
- (BOOL)startWithText:(NSString *)text
             typoPath:(nullable NSString *)typoPath
               config:(MTConfig)config
                error:(NSString *_Nullable *_Nullable)error;
- (BOOL)updatePaused:(BOOL)paused;
/// 请求结束；任务真正结束后会回调 engineDidFinish:。
- (BOOL)stop;
@end

NS_ASSUME_NONNULL_END
