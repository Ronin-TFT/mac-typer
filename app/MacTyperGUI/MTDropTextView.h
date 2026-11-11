#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// 可拖入文本文件的输入框：拖入文件时用文件内容替换全部文字（可撤销）。
@interface MTDropTextView : NSTextView
/// 拖入文件后调用；读取失败时 error 不为空。
@property (nonatomic, copy, nullable) void (^importHandler)(NSURL *url, NSError *_Nullable error);
- (void)replaceAllText:(NSString *)text;
@end

NS_ASSUME_NONNULL_END
