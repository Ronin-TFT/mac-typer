#import "MTScreenRecorder.h"
#import <AVFoundation/AVFoundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <math.h>
#import <unistd.h>

static NSError *MTRecorderError(NSString *message) {
    return [NSError errorWithDomain:@"MacTyper.Recorder" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

CGRect MTDisplayLocalRect(CGRect globalRect, CGRect screenFrame) {
    CGRect r = CGRectIntersection(CGRectStandardize(globalRect), screenFrame);
    if (CGRectIsNull(r) || CGRectIsEmpty(r)) return CGRectNull;
    return CGRectMake(r.origin.x - screenFrame.origin.x,
                      CGRectGetMaxY(screenFrame) - CGRectGetMaxY(r),
                      r.size.width, r.size.height);
}

CGSize MTEncodedSize(CGSize pixels) {
    double width = MAX(pixels.width, 2), height = MAX(pixels.height, 2);
    double scale = MIN(1.0, MIN(4096.0 / width, 2304.0 / height));
    long w = (long)floor(width * scale), h = (long)floor(height * scale);
    w -= w % 2;
    h -= h % 2;
    return CGSizeMake(MAX(w, 2), MAX(h, 2));
}

NSString *MTRecordingFileName(NSDate *date) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd HH.mm.ss";
    return [NSString stringWithFormat:@"Mac Typer 录屏 %@.mp4", [formatter stringFromDate:date]];
}

@interface MTScreenRecorder () <SCStreamOutput, SCStreamDelegate>
@property (nonatomic, readwrite, getter=isRecording) BOOL recording;
@property (nonatomic, readwrite, getter=isBusy) BOOL busy;
@property (nonatomic, readwrite, nullable) NSURL *outputURL;
@property (nonatomic, readwrite, nullable) NSDate *startedAt;
@property (nonatomic, strong, nullable) SCStream *stream;
// 以下在采样队列上读取，用 atomic 保证与主线程之间的可见性。
@property (atomic, strong, nullable) AVAssetWriter *writer;
@property (atomic, strong, nullable) AVAssetWriterInput *input;
@property (atomic) BOOL sessionStarted;
@property (nonatomic, strong) dispatch_queue_t sampleQueue;
@end

@implementation MTScreenRecorder

- (instancetype)init {
    if ((self = [super init])) {
        _sampleQueue = dispatch_queue_create("MacTyper.ScreenRecorder", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)startOnDisplay:(CGDirectDisplayID)displayID rect:(CGRect)rect scale:(CGFloat)scale fps:(NSInteger)fps
           showsCursor:(BOOL)showsCursor outputURL:(NSURL *)url completion:(void (^)(NSError *))completion {
    if (self.recording || self.busy) {
        completion(MTRecorderError(@"已经在录屏"));
        return;
    }
    self.busy = YES;
    void (^fail)(NSError *) = ^(NSError *error) {
        self.busy = NO;
        self.stream = nil;
        self.writer = nil;
        self.input = nil;
        completion(error);
    };

    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES
                                                 completionHandler:^(SCShareableContent *content, NSError *contentError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (contentError || !content) {
                fail(contentError ?: MTRecorderError(@"无法获取屏幕内容"));
                return;
            }
            SCDisplay *display = nil;
            for (SCDisplay *candidate in content.displays) {
                if (candidate.displayID == displayID) display = candidate;
            }
            if (!display) {
                fail(MTRecorderError(@"找不到要录制的屏幕，请重新选择"));
                return;
            }
            NSMutableArray<SCRunningApplication *> *excluded = [NSMutableArray array];
            for (SCRunningApplication *app in content.applications) {
                if (app.processID == getpid()) [excluded addObject:app];
            }
            SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display
                                                         excludingApplications:excluded
                                                              exceptingWindows:@[]];

            CGRect source = CGRectIsNull(rect) ? CGRectMake(0, 0, display.width, display.height) : rect;
            CGFloat pixelScale = scale > 0 ? scale : 1;
            CGSize size = MTEncodedSize(CGSizeMake(source.size.width * pixelScale, source.size.height * pixelScale));
            NSInteger frameRate = fps > 0 ? fps : 30;

            SCStreamConfiguration *config = [SCStreamConfiguration new];
            if (!CGRectIsNull(rect)) config.sourceRect = rect;
            config.width = (size_t)size.width;
            config.height = (size_t)size.height;
            config.minimumFrameInterval = CMTimeMake(1, (int32_t)frameRate);
            config.showsCursor = showsCursor;
            config.pixelFormat = kCVPixelFormatType_32BGRA;
            config.queueDepth = 6;

            [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
                                   withIntermediateDirectories:YES attributes:nil error:NULL];
            NSError *writerError = nil;
            AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeMPEG4 error:&writerError];
            if (!writer) {
                fail(writerError ?: MTRecorderError(@"无法创建录屏文件"));
                return;
            }
            double bitRate = MAX(2e6, size.width * size.height * frameRate * 0.1);
            NSDictionary *settings = @{
                AVVideoCodecKey: AVVideoCodecTypeH264,
                AVVideoWidthKey: @(size.width),
                AVVideoHeightKey: @(size.height),
                AVVideoCompressionPropertiesKey: @{
                    AVVideoAverageBitRateKey: @(bitRate),
                    AVVideoExpectedSourceFrameRateKey: @(frameRate),
                    AVVideoMaxKeyFrameIntervalKey: @(frameRate * 2),
                },
            };
            AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
            input.expectsMediaDataInRealTime = YES;
            if (![writer canAddInput:input]) {
                fail(MTRecorderError(@"无法使用该尺寸编码视频"));
                return;
            }
            [writer addInput:input];
            if (![writer startWriting]) {
                fail(writer.error ?: MTRecorderError(@"无法开始写入录屏文件"));
                return;
            }
            self.writer = writer;
            self.input = input;
            self.sessionStarted = NO;

            SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
            NSError *outputError = nil;
            if (![stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.sampleQueue error:&outputError]) {
                [writer cancelWriting];
                fail(outputError ?: MTRecorderError(@"无法接收屏幕画面"));
                return;
            }
            self.stream = stream;
            [stream startCaptureWithCompletionHandler:^(NSError *startError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (startError) {
                        [writer cancelWriting];
                        [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
                        fail(startError);
                        return;
                    }
                    self.busy = NO;
                    self.recording = YES;
                    self.outputURL = url;
                    self.startedAt = [NSDate date];
                    completion(nil);
                });
            }];
        });
    }];
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sampleBuffer)) return;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (!attachments || CFArrayGetCount(attachments) == 0) return;
    NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments, 0);
    NSNumber *status = info[SCStreamFrameInfoStatus];
    if (!status || status.integerValue != SCFrameStatusComplete) return;

    AVAssetWriter *writer = self.writer;
    AVAssetWriterInput *input = self.input;
    if (!writer || !input || writer.status != AVAssetWriterStatusWriting) return;
    if (!self.sessionStarted) {
        [writer startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp(sampleBuffer)];
        self.sessionStarted = YES;
    }
    if (input.readyForMoreMediaData) [input appendSampleBuffer:sampleBuffer];
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.recording || stream != self.stream) return;
        void (^handler)(NSURL *, NSError *) = self.unexpectedStopHandler;
        [self stopWithCompletion:^(NSURL *url, NSError *stopError) {
            if (handler) handler(url, error ?: stopError);
        }];
    });
}

- (void)stopWithCompletion:(void (^)(NSURL *, NSError *))completion {
    if (!self.recording || !self.stream) {
        completion(nil, MTRecorderError(@"没有正在进行的录屏"));
        return;
    }
    SCStream *stream = self.stream;
    NSURL *url = self.outputURL;
    self.recording = NO;
    self.busy = YES;
    void (^finish)(NSURL *, NSError *) = ^(NSURL *savedURL, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.stream = nil;
            self.busy = NO;
            self.startedAt = nil;
            completion(savedURL, error);
        });
    };
    [stream stopCaptureWithCompletionHandler:^(NSError *stopError) {
        // 在采样队列上收尾，确保已经收到的画面都写完。
        dispatch_async(self.sampleQueue, ^{
            AVAssetWriter *writer = self.writer;
            AVAssetWriterInput *input = self.input;
            self.writer = nil;
            self.input = nil;
            if (!writer) {
                finish(nil, MTRecorderError(@"录屏文件已丢失"));
                return;
            }
            if (!self.sessionStarted) {
                [writer cancelWriting];
                [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
                finish(nil, MTRecorderError(@"没有录到画面：请确认已在“屏幕与系统录音”中允许 Mac Typer"));
                return;
            }
            [input markAsFinished];
            [writer finishWritingWithCompletionHandler:^{
                if (writer.status == AVAssetWriterStatusCompleted) {
                    finish(url, nil);
                } else {
                    finish(nil, writer.error ?: MTRecorderError(@"保存录屏失败"));
                }
            }];
        });
    }];
}

@end
