#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 键盘输入源（输入法）切换。只能在主线程调用。
@interface MTInputSource : NSObject
/// 当前输入源是否为英文等可直接输入 ASCII 的键盘布局。
+ (BOOL)currentIsASCIICapable;
/// 当前是中文等输入法时切换到英文键盘布局，返回原输入源用于恢复；无需切换或失败时返回 nil。
+ (nullable id)switchToASCIICapable;
+ (void)restore:(nullable id)saved;
@end

NS_ASSUME_NONNULL_END
