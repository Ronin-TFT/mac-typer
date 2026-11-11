#import <Cocoa/Cocoa.h>
#import "MTEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface MTAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, MTEngineDelegate>
@property (nonatomic, strong) MTEngine *engine;
/// 关闭窗口后是否保留在菜单栏继续响应快捷键。
@property (nonatomic) BOOL keepInMenuBar;

- (IBAction)showMainWindow:(nullable id)sender;
- (IBAction)startTyping:(nullable id)sender;
- (IBAction)togglePause:(nullable id)sender;
- (IBAction)stopTyping:(nullable id)sender;
- (IBAction)importText:(nullable id)sender;
@end

NS_ASSUME_NONNULL_END
