// Run: clang -fobjc-arc tests/gui_test.m -framework Cocoa -framework ApplicationServices -framework Carbon -o build/gui-test && build/gui-test
#define main MacTyperApplicationMain
#import "../app/MacTyperGUI/main.m"
#undef main
#include <assert.h>
#include <sys/wait.h>

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
        [delegate togglePause:nil];
        int processStatus;
        assert(waitpid(delegate.task.processIdentifier, &processStatus, WUNTRACED) > 0);
        assert(WIFSTOPPED(processStatus));
        assert(delegate.taskPaused && delegate.task.isRunning);
        [delegate togglePause:nil];
        assert(!delegate.taskPaused && delegate.task.isRunning);
        [delegate togglePause:nil];
        assert(waitpid(delegate.task.processIdentifier, &processStatus, WUNTRACED) > 0);
        [delegate applicationWillTerminate:nil];
        assert(!delegate.task.isRunning);

        delegate.task = [NSTask new];
        delegate.task.executableURL = [NSURL fileURLWithPath:@"/bin/sleep"];
        delegate.task.arguments = @[@"30"];
        delegate.taskPaused = NO;
        assert([delegate.task launchAndReturnError:NULL]);
        [delegate togglePause:nil];
        assert(waitpid(delegate.task.processIdentifier, &processStatus, WUNTRACED) > 0);
        [delegate stopTyping:nil];
        [delegate.task waitUntilExit];
        assert(!delegate.task.isRunning);

        [NSApplication sharedApplication];
        NSTextField *field = [NSTextField new];
        NSPopUpButton *unit = [NSPopUpButton new];
        [unit addItemsWithTitles:@[@"ms", @"秒"]];
        field.stringValue = @" 1e2 ";
        assert([[delegate durationArg:field unit:unit] isEqualToString:@"100000000ns"]);
        [unit selectItemWithTitle:@"秒"];
        field.stringValue = @"0.25";
        assert([[delegate durationArg:field unit:unit] isEqualToString:@"250000000ns"]);
        puts("GUI cancellation, pause/resume, paused child cleanup and numeric arguments passed");
    }
    return 0;
}
