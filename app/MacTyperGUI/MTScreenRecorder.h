#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// 把 Cocoa 全局坐标（左下角原点）中的区域转换为该屏幕内的坐标（左上角原点，单位为点）。
/// 区域与屏幕不相交时返回 CGRectNull。
CGRect MTDisplayLocalRect(CGRect globalRect, CGRect screenFrame);

/// 视频编码尺寸：保持比例缩放到不超过 4096×2304，宽高取偶数。
CGSize MTEncodedSize(CGSize pixels);

/// 录屏文件名，例如“Mac Typer 录屏 2026-11-11 15.30.12.mp4”。
NSString *MTRecordingFileName(NSDate *date);

/// 使用 ScreenCaptureKit 录制屏幕或屏幕中的一块区域，编码为 H.264 MP4。
/// Mac Typer 自己的窗口（主窗口、选区边框）不会出现在录像里。只能在主线程调用。
@interface MTScreenRecorder : NSObject
@property (nonatomic, readonly, getter=isRecording) BOOL recording;
@property (nonatomic, readonly, getter=isBusy) BOOL busy;
@property (nonatomic, readonly, nullable) NSURL *outputURL;
@property (nonatomic, readonly, nullable) NSDate *startedAt;
/// 录制被系统中断（如权限被撤销、显示器断开）时调用，文件已尽量保存。
@property (nonatomic, copy, nullable) void (^unexpectedStopHandler)(NSURL *_Nullable url, NSError *_Nullable error);

/// rect 为屏幕内坐标（点，左上角原点）；传 CGRectNull 录制整个屏幕。completion 在主线程调用。
- (void)startOnDisplay:(CGDirectDisplayID)displayID
                  rect:(CGRect)rect
                 scale:(CGFloat)scale
                   fps:(NSInteger)fps
           showsCursor:(BOOL)showsCursor
             outputURL:(NSURL *)url
            completion:(void (^)(NSError *_Nullable error))completion;

/// 停止并写完文件。completion 在主线程调用，成功时返回文件位置。
- (void)stopWithCompletion:(void (^)(NSURL *_Nullable url, NSError *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
