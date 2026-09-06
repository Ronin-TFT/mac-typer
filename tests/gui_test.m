// Run: clang -fobjc-arc tests/gui_test.m -framework Cocoa -framework ApplicationServices -framework Carbon -o build/gui-test && build/gui-test
#define main MacTyperApplicationMain
#import "../app/MacTyperGUI/main.m"
#undef main
#include <assert.h>

@interface TestDelegate : AppDelegate
@property NSUInteger posted;
@end
@implementation TestDelegate
- (void)postText:(NSString *)text { self.posted += text.length; }
- (void)postBackspaces:(NSInteger)count { self.posted += count; }
- (void)saveSettings {}
@end

int main(void) {
    @autoreleasepool {
        TestDelegate *delegate = [TestDelegate new];
        delegate.acceptingEvents = YES;
        [delegate handleEventLine:@"TQQ=="];
        assert(delegate.posted == 1);
        delegate.startPending = YES;
        NSUInteger generation = delegate.startGeneration;
        [delegate stopTyping:nil];
        assert(!delegate.startPending && delegate.startGeneration != generation);
        [delegate handleEventLine:@"TQg=="];
        [delegate handleEventLine:@"B1"];
        assert(delegate.posted == 1);
        assert([delegate applicationShouldTerminateAfterLastWindowClosed:nil]);

        delegate.task = [NSTask new];
        delegate.task.executableURL = [NSURL fileURLWithPath:@"/bin/sleep"];
        delegate.task.arguments = @[@"30"];
        assert([delegate.task launchAndReturnError:NULL]);
        [delegate applicationWillTerminate:nil];
        assert(!delegate.task.isRunning);
        puts("GUI event suppression, cancellation and child cleanup passed");
    }
    return 0;
}
