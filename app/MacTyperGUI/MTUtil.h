#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 严格解析 [0, max] 内的数字，允许首尾空白和科学记数法；integer 为 YES 时必须是整数。
BOOL MTParseNumber(NSString *string, double max, BOOL integer, double *_Nullable value);

/// 把秒数格式化为 m:ss 或 h:mm:ss。
NSString *MTDurationText(NSTimeInterval seconds);

/// 进度描述，例如“已输入 120/800 · 约剩 1:30”。activeSeconds 为不含暂停的输入用时。
NSString *MTProgressText(NSInteger done, NSInteger total, NSTimeInterval activeSeconds);

/// 读取纯文本文件：依次识别 UTF-16（带 BOM）、UTF-8、GB18030，最大 10 MB。
NSString *_Nullable MTReadTextFile(NSURL *url, NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
