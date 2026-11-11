// 界面层回归测试（不发送真实按键，引擎使用 dry_run）。
// 构建：
//   go build -buildmode=c-archive -o build/libmactyper.a .
//   clang -fobjc-arc -I build -I . -I app/MacTyperGUI tests/gui_test.m app/MacTyperGUI/MT*.m build/libmactyper.a \
//     -framework Cocoa -framework ApplicationServices -framework Carbon -framework CoreFoundation -o build/gui-test
//   build/gui-test
#import <Cocoa/Cocoa.h>
#include <assert.h>
#import "MTAppDelegate.h"
#import "MTDropTextView.h"
#import "MTEngine.h"
#import "MTHotkeys.h"
#import "MTInputSource.h"
#import "MTUtil.h"

@interface EngineObserver : NSObject <MTEngineDelegate>
@property NSInteger countdowns, done, total, readies;
@property BOOL finished;
@property MTFinishReason reason;
@end
@implementation EngineObserver
- (void)engineDidCountdown:(NSInteger)seconds { self.countdowns++; }
- (void)engineDidProgress:(NSInteger)done total:(NSInteger)total { self.done = done; self.total = total; }
- (void)engineDidFinish:(MTFinishReason)reason message:(NSString *)message { self.finished = YES; self.reason = reason; }
- (void)engineIsReady { self.readies++; }
@end

static void spin(NSTimeInterval seconds, BOOL (^until)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ((!until || !until()) && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

static NSURL *writeTemp(NSString *name, NSData *data) {
    NSURL *url = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:name];
    assert([data writeToURL:url atomically:YES]);
    return url;
}

static MTConfig dryConfig(void) {
    MTConfig config = {0};
    config.dry_run = 1;
    config.typo_rate = 1;
    return config;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];

        // 数字校验与进度文字
        double value = 0;
        assert(MTParseNumber(@" 1e2 ", 1000, NO, &value) && value == 100);
        assert(!MTParseNumber(@"-1", 10, NO, NULL));
        assert(!MTParseNumber(@"abc", 10, NO, NULL));
        assert(!MTParseNumber(@"1.5", 10, YES, NULL));
        assert(!MTParseNumber(@"inf", 10, NO, NULL));
        assert(!MTParseNumber(@"61", 60, NO, NULL));
        assert([MTDurationText(3725) isEqualToString:@"1:02:05"]);
        assert([MTDurationText(65) isEqualToString:@"1:05"]);
        assert([MTProgressText(0, 10, 0) isEqualToString:@"已输入 0/10"]);
        assert([MTProgressText(5, 10, 5) isEqualToString:@"已输入 5/10 · 约剩 0:05"]);

        // 文本文件导入：UTF-8 BOM、UTF-16、GB18030、二进制
        NSMutableData *utf8 = [NSMutableData dataWithBytes:"\xEF\xBB\xBF" length:3];
        [utf8 appendData:[@"你好 hello" dataUsingEncoding:NSUTF8StringEncoding]];
        assert([MTReadTextFile(writeTemp(@"mt-utf8.txt", utf8), NULL) isEqualToString:@"你好 hello"]);
        NSData *utf16 = [@"你好" dataUsingEncoding:NSUTF16StringEncoding];
        assert([MTReadTextFile(writeTemp(@"mt-utf16.txt", utf16), NULL) isEqualToString:@"你好"]);
        NSData *gb = [@"中文文本" dataUsingEncoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000)];
        assert([MTReadTextFile(writeTemp(@"mt-gb.txt", gb), NULL) isEqualToString:@"中文文本"]);
        NSError *error = nil;
        assert(!MTReadTextFile(writeTemp(@"mt-bin.dat", [NSData dataWithBytes:"\x89PNG\0\0" length:6]), &error) && error);

        MTDropTextView *textView = [[MTDropTextView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
        textView.string = @"old";
        [textView replaceAllText:@"new text"];
        assert([textView.string isEqualToString:@"new text"]);
        assert([textView.acceptableDragTypes containsObject:NSPasteboardTypeFileURL]);

        // 快捷键
        NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
                                     modifierFlags:NSEventModifierFlagCommand | NSEventModifierFlagOption
                                         timestamp:0 windowNumber:0 context:nil characters:@"∫"
                       charactersIgnoringModifiers:@"b" isARepeat:NO keyCode:11];
        MTHotkey *hotkey = [MTHotkey hotkeyWithEvent:event];
        assert(hotkey && hotkey.keyCode == 11 && [hotkey.displayName isEqualToString:@"⌥⌘B"]);
        NSEvent *plain = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
                                         timestamp:0 windowNumber:0 context:nil characters:@"b"
                       charactersIgnoringModifiers:@"b" isARepeat:NO keyCode:11];
        assert([MTHotkey hotkeyWithEvent:plain] == nil);
        MTHotkey *same = [[MTHotkey alloc] initWithKeyCode:11 modifiers:NSEventModifierFlagCommand | NSEventModifierFlagOption displayName:@"x"];
        MTHotkey *other = [[MTHotkey alloc] initWithKeyCode:11 modifiers:NSEventModifierFlagCommand displayName:@"x"];
        assert([hotkey isEqualToHotkey:same] && ![hotkey isEqualToHotkey:other]);

        // 输入源查询可调用（不切换，避免影响运行测试的机器）
        (void)[MTInputSource currentIsASCIICapable];

        // 引擎：完成
        EngineObserver *observer = [EngineObserver new];
        MTEngine *engine = [MTEngine new];
        engine.delegate = observer;
        NSString *message = nil;
        assert([engine startWithText:@"hello 你好" typoPath:nil config:dryConfig() error:&message]);
        assert(engine.running);
        assert(![engine startWithText:@"again" typoPath:nil config:dryConfig() error:&message] && message.length);
        spin(3, ^BOOL { return observer.finished; });
        assert(observer.finished && observer.reason == MTFinishReasonDone);
        assert(observer.done == 8 && observer.total == 8 && !engine.running);

        // 引擎：参数错误不启动
        MTConfig bad = dryConfig();
        bad.slip_rate = 3;
        message = nil;
        assert(![engine startWithText:@"hello" typoPath:nil config:bad error:&message] && [message containsString:@"手误"]);
        assert(![engine startWithText:@"hello" typoPath:@"/nonexistent/typos.txt" config:dryConfig() error:&message]);
        assert(!engine.running);

        // 引擎：暂停不再前进，结束可打断
        observer = [EngineObserver new];
        engine.delegate = observer;
        MTConfig slow = dryConfig();
        slow.delay_ns = 10 * 1000 * 1000;
        assert([engine startWithText:[@"" stringByPaddingToLength:200 withString:@"x" startingAtIndex:0]
                            typoPath:nil config:slow error:NULL]);
        spin(0.2, nil);
        assert([engine updatePaused:YES] && engine.paused);
        spin(0.1, nil);
        NSInteger pausedAt = observer.done;
        spin(0.3, nil);
        assert(observer.done - pausedAt <= 1);
        assert([engine updatePaused:NO] && !engine.paused);
        spin(0.1, nil);
        assert(observer.done > pausedAt);
        assert([engine stop] && engine.stopping);
        spin(2, ^BOOL { return observer.finished; });
        assert(observer.finished && observer.reason == MTFinishReasonStopped && observer.done < 200);
        assert(![engine stop] && ![engine updatePaused:YES]);

        // 引擎：wait_ready 时在准备好之前不输入
        observer = [EngineObserver new];
        engine.delegate = observer;
        MTConfig gated = dryConfig();
        gated.wait_ready = 1;
        assert([engine startWithText:@"gate" typoPath:nil config:gated error:NULL]);
        spin(0.3, ^BOOL { return observer.readies > 0; });
        spin(0.1, nil);
        assert(observer.readies == 1 && observer.done == 0 && !observer.finished);
        [engine continueAfterReady];
        spin(2, ^BOOL { return observer.finished; });
        assert(observer.reason == MTFinishReasonDone && observer.done == 4);

        // 菜单栏模式决定关闭窗口后是否退出
        MTAppDelegate *delegate = [MTAppDelegate new];
        delegate.keepInMenuBar = NO;
        assert([delegate applicationShouldTerminateAfterLastWindowClosed:NSApp]);
        delegate.keepInMenuBar = YES;
        assert(![delegate applicationShouldTerminateAfterLastWindowClosed:NSApp]);

        puts("GUI utilities, text import, hotkeys, input source, engine bridge, ready gate and menu bar mode passed");
    }
    return 0;
}
