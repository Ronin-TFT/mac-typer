#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// “录屏”页：录制范围（整个屏幕或自定义区域）、帧率、鼠标指针、保存位置，以及随键入自动录屏。
@interface MTRecordingController : NSObject <NSMenuItemValidation>
@property (nonatomic, readonly) NSTabViewItem *tabItem;
@property (nonatomic, readonly, getter=isRecording) BOOL recording;
@property (nonatomic, readonly, getter=isBusy) BOOL busy;
/// 是否开启“键入时自动录屏”。
@property (nonatomic, readonly) BOOL autoRecordWithTyping;
/// 状态文字输出到主窗口底部。
@property (nonatomic, copy, nullable) void (^statusHandler)(NSString *message);
/// 选择区域时会暂时隐藏的主窗口。
@property (nonatomic, weak, nullable) NSWindow *mainWindow;

- (IBAction)toggleRecording:(nullable id)sender;
/// 键入即将开始：开启自动录屏时先开始录制，然后调用 ready（录制失败也会调用）。
- (void)typingWillStart:(void (^)(void))ready;
/// 键入结束：如果录屏是随键入自动开始的，稍后停止。
- (void)typingDidEnd;
/// 退出前停止录屏并保存文件。
- (void)stopForTerminationWithCompletion:(void (^)(void))completion;
- (void)saveSettings;
@end

NS_ASSUME_NONNULL_END
