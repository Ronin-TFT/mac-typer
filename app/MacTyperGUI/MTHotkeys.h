#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, MTHotkeyAction) {
    MTHotkeyActionStart = 1,
    MTHotkeyActionPause = 2,
    MTHotkeyActionStop = 3,
};

@interface MTHotkey : NSObject
@property (nonatomic, readonly) NSUInteger keyCode;
@property (nonatomic, readonly) NSEventModifierFlags modifiers;
@property (nonatomic, readonly, copy) NSString *displayName;
- (instancetype)initWithKeyCode:(NSUInteger)keyCode modifiers:(NSEventModifierFlags)modifiers displayName:(NSString *)displayName;
/// 从按键事件生成快捷键；没有 Command、Option 或 Control 时返回 nil。
+ (nullable instancetype)hotkeyWithEvent:(NSEvent *)event;
@end

/// 全局快捷键（Carbon），应用在后台时也能触发。
@interface MTHotkeyCenter : NSObject
@property (nonatomic, copy, nullable) void (^handler)(MTHotkeyAction action);
- (BOOL)install;
/// hotkeys 依次为开始、暂停/继续、结束。任一注册失败则全部注销并返回 NO。
- (BOOL)registerHotkeys:(NSArray<MTHotkey *> *)hotkeys;
- (void)unregisterAll;
- (void)uninstall;
@end

NS_ASSUME_NONNULL_END
