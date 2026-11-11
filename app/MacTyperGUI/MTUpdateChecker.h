#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 比较版本号，例如 "v1.10.0" > "1.9.2"；忽略开头的 v，缺少的段按 0 处理。
NSComparisonResult MTCompareVersions(NSString *a, NSString *b);

/// 查询 GitHub 最新 Release。只读取公开的版本信息，不下载、不安装。
@interface MTUpdateChecker : NSObject
/// completion 在主线程调用：latest 为最新版本号（去掉 v），url 为发布页面。
+ (void)fetchLatestWithCompletion:(void (^)(NSString *_Nullable latest, NSURL *_Nullable url, NSError *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
