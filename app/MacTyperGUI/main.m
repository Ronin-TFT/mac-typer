#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <signal.h>
#import <math.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@property NSTabView *tabs;
@property NSTextView *textView;
@property NSTextView *wordsView;
@property NSTextField *typoField;
@property NSTextField *delayField;
@property NSPopUpButton *delayUnit;
@property NSTextField *jitterField;
@property NSPopUpButton *jitterUnit;
@property NSTextField *countdownField;
@property NSTextField *startHotkeyField;
@property NSTextField *pauseHotkeyField;
@property NSTextField *stopHotkeyField;
@property NSTextField *hotkeyDelayField;
@property NSTextField *statusField;
@property NSButton *startButton;
@property NSTask *task;
@property BOOL startPending;
@property BOOL taskPaused;
@property NSUInteger startGeneration;
@property NSFileHandle *eventReader;
@property BOOL acceptingEvents;
@property NSString *recordingAction;
@property NSUInteger startHotkeyCode;
@property NSEventModifierFlags startHotkeyMods;
@property NSUInteger pauseHotkeyCode;
@property NSEventModifierFlags pauseHotkeyMods;
@property NSUInteger stopHotkeyCode;
@property NSEventModifierFlags stopHotkeyMods;
@property EventHandlerRef hotkeyHandler;
@property EventHotKeyRef startHotkey;
@property EventHotKeyRef pauseHotkey;
@property EventHotKeyRef stopHotkey;
- (void)handleRegisteredHotkey:(NSNumber *)hotkeyID;
@end

static OSStatus MacTyperHotkeyHandler(EventHandlerCallRef nextHandler, EventRef event, void *userData) {
    EventHotKeyID hotkeyID;
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL,
                          sizeof(hotkeyID), NULL, &hotkeyID) != noErr) return eventNotHandledErr;
    AppDelegate *delegate = (__bridge AppDelegate *)userData;
    [delegate handleRegisteredHotkey:@(hotkeyID.id)];
    return noErr;
}

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.startHotkeyCode = 11;
    self.startHotkeyMods = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    self.pauseHotkeyCode = 45;
    self.pauseHotkeyMods = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    self.stopHotkeyCode = 46;
    self.stopHotkeyMods = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:@"startHotkeyCode"]) {
        self.startHotkeyCode = [defaults integerForKey:@"startHotkeyCode"];
        self.startHotkeyMods = [defaults integerForKey:@"startHotkeyMods"];
        self.pauseHotkeyCode = [defaults integerForKey:@"pauseHotkeyCode"];
        self.pauseHotkeyMods = [defaults integerForKey:@"pauseHotkeyMods"];
        self.stopHotkeyCode = [defaults integerForKey:@"stopHotkeyCode"];
        self.stopHotkeyMods = [defaults integerForKey:@"stopHotkeyMods"];
    }
    [self buildWindow];
    for (NSString *key in @[@"delayField", @"jitterField", @"countdownField", @"typoField"]) {
        NSString *value = [defaults stringForKey:key];
        if (value) [[self valueForKey:key] setStringValue:value];
    }
    [self.delayUnit selectItemWithTitle:[defaults stringForKey:@"delayUnit"] ?: @"ms"];
    [self.jitterUnit selectItemWithTitle:[defaults stringForKey:@"jitterUnit"] ?: @"ms"];
    if ([defaults stringForKey:@"startHotkeyName"]) self.startHotkeyField.stringValue = [defaults stringForKey:@"startHotkeyName"];
    if ([defaults stringForKey:@"pauseHotkeyName"]) self.pauseHotkeyField.stringValue = [defaults stringForKey:@"pauseHotkeyName"];
    if ([defaults stringForKey:@"stopHotkeyName"]) self.stopHotkeyField.stringValue = [defaults stringForKey:@"stopHotkeyName"];
    if ([defaults objectForKey:@"hotkeyDelay"]) self.hotkeyDelayField.doubleValue = [defaults doubleForKey:@"hotkeyDelay"];
    [self installHotkeyMonitor];
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app { return YES; }

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }

- (BOOL)validateSettings {
    NSArray *fields = @[self.delayField, self.jitterField, self.countdownField, self.hotkeyDelayField];
    NSArray *limits = @[@([self.delayUnit.titleOfSelectedItem isEqualToString:@"秒"] ? 60 : 60000),
                        @([self.jitterUnit.titleOfSelectedItem isEqualToString:@"秒"] ? 60 : 60000), @3600, @3600];
    for (NSUInteger i = 0; i < fields.count; i++) {
        NSTextField *field = fields[i];
        NSScanner *scanner = [NSScanner scannerWithString:field.stringValue];
        double value;
        if (![scanner scanDouble:&value] || !scanner.isAtEnd || !isfinite(value) || value < 0 || value > [limits[i] doubleValue] || (i == 2 && floor(value) != value)) {
            [self showError:@"间隔和抖动须为 0–60 秒；倒计时须为 0–3600 的整数；快捷键延迟须为 0–3600 秒。"];
            return NO;
        }
    }
    return YES;
}

- (void)buildWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 620)
                                             styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    self.window.title = @"Mac Typer";
    [self.window center];

    NSView *content = self.window.contentView;
    [content addSubview:[self label:@"Mac Typer" frame:NSMakeRect(24, 574, 260, 28) size:24 bold:YES]];
    [content addSubview:[self label:@"模拟键入 · 随机抖动 · 错词删除库" frame:NSMakeRect(24, 548, 360, 22) size:13 bold:NO]];

    self.tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(20, 78, 720, 455)];
    [content addSubview:self.tabs];
    [self addMainTab];
    [self addTypoToolTab];
    [self addSettingsTab];

    self.statusField = [self label:@"准备就绪" frame:NSMakeRect(24, 28, 420, 24) size:13 bold:NO];
    [content addSubview:self.statusField];
    self.startButton = [self button:@"开始" frame:NSMakeRect(432, 22, 92, 34) action:@selector(startTyping:)];
    [content addSubview:self.startButton];
    [content addSubview:[self button:@"暂停/继续" frame:NSMakeRect(532, 22, 96, 34) action:@selector(togglePause:)]];
    [content addSubview:[self button:@"结束" frame:NSMakeRect(636, 22, 80, 34) action:@selector(stopTyping:)]];

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)addMainTab {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"main"];
    item.label = @"输入";
    NSView *v = [[NSView alloc] initWithFrame:self.tabs.bounds];
    [v addSubview:[self label:@"输入内容" frame:NSMakeRect(18, 392, 120, 22) size:14 bold:YES]];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(18, 176, 684, 210)];
    scroll.hasVerticalScroller = YES;
    self.textView = [[NSTextView alloc] initWithFrame:scroll.bounds];
    self.textView.string = @"this is the address";
    self.textView.font = [NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular];
    scroll.documentView = self.textView;
    [v addSubview:scroll];

    self.typoField = [self field:@"" frame:NSMakeRect(18, 130, 570, 28)];
    self.typoField.placeholderString = @"错词库路径，可留空";
    [v addSubview:self.typoField];
    [v addSubview:[self button:@"选择错词库" frame:NSMakeRect(596, 128, 106, 32) action:@selector(chooseTypoFile:)]];

    [v addSubview:[self label:@"基础间隔" frame:NSMakeRect(18, 82, 90, 20) size:13 bold:NO]];
    self.delayField = [self field:@"80" frame:NSMakeRect(18, 54, 90, 28)];
    [v addSubview:self.delayField];
    self.delayUnit = [self unitPopup:NSMakeRect(112, 54, 70, 28)];
    [v addSubview:self.delayUnit];

    [v addSubview:[self label:@"随机抖动" frame:NSMakeRect(230, 82, 90, 20) size:13 bold:NO]];
    self.jitterField = [self field:@"60" frame:NSMakeRect(230, 54, 90, 28)];
    [v addSubview:self.jitterField];
    self.jitterUnit = [self unitPopup:NSMakeRect(324, 54, 70, 28)];
    [v addSubview:self.jitterUnit];

    [v addSubview:[self label:@"倒计时秒" frame:NSMakeRect(442, 82, 90, 20) size:13 bold:NO]];
    self.countdownField = [self field:@"5" frame:NSMakeRect(442, 54, 90, 28)];
    [v addSubview:self.countdownField];

    item.view = v;
    [self.tabs addTabViewItem:item];
}

- (void)addTypoToolTab {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"typos"];
    item.label = @"错词库工具";
    NSView *v = [[NSView alloc] initWithFrame:self.tabs.bounds];
    [v addSubview:[self label:@"每行写：原词=>错词，例如 mother=>motter" frame:NSMakeRect(18, 392, 420, 22) size:14 bold:YES]];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(18, 78, 684, 304)];
    scroll.hasVerticalScroller = YES;
    self.wordsView = [[NSTextView alloc] initWithFrame:scroll.bounds];
    self.wordsView.string = @"mother=>motter\naddress=>adress\nthe=>teh";
    self.wordsView.font = [NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular];
    scroll.documentView = self.wordsView;
    [v addSubview:scroll];
    [v addSubview:[self button:@"生成错词库文档" frame:NSMakeRect(18, 28, 150, 34) action:@selector(saveTypoDoc:)]];
    item.view = v;
    [self.tabs addTabViewItem:item];
}

- (void)addSettingsTab {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"settings"];
    item.label = @"设置";
    NSView *v = [[NSView alloc] initWithFrame:self.tabs.bounds];
    [v addSubview:[self label:@"快捷键" frame:NSMakeRect(18, 392, 130, 22) size:14 bold:YES]];
    self.startHotkeyField = [self field:@"⌥⌘B" frame:NSMakeRect(18, 354, 120, 28)];
    self.startHotkeyField.editable = NO;
    [v addSubview:self.startHotkeyField];
    NSButton *startRecord = [self button:@"录制开始" frame:NSMakeRect(146, 352, 100, 32) action:@selector(recordStartHotkey:)];
    [v addSubview:startRecord];
    self.pauseHotkeyField = [self field:@"⌥⌘N" frame:NSMakeRect(266, 354, 120, 28)];
    self.pauseHotkeyField.editable = NO;
    [v addSubview:self.pauseHotkeyField];
    NSButton *pauseRecord = [self button:@"录制暂停" frame:NSMakeRect(394, 352, 100, 32) action:@selector(recordPauseHotkey:)];
    [v addSubview:pauseRecord];
    self.stopHotkeyField = [self field:@"⌥⌘M" frame:NSMakeRect(514, 354, 120, 28)];
    self.stopHotkeyField.editable = NO;
    [v addSubview:self.stopHotkeyField];
    NSButton *stopRecord = [self button:@"录制结束" frame:NSMakeRect(642, 352, 72, 32) action:@selector(recordStopHotkey:)];
    [v addSubview:stopRecord];

    [v addSubview:[self label:@"快捷键启动延迟（秒）" frame:NSMakeRect(18, 302, 180, 22) size:14 bold:YES]];
    self.hotkeyDelayField = [self field:@"0" frame:NSMakeRect(18, 264, 110, 28)];
    [v addSubview:self.hotkeyDelayField];

    [v addSubview:[self button:@"测试辅助功能权限" frame:NSMakeRect(18, 210, 150, 34) action:@selector(testPermission:)]];
    [v addSubview:[self label:@"教程：系统设置 > 隐私与安全性 > 辅助功能，打开 Mac Typer。快捷键可在后台使用，请通过上方录制按钮修改。" frame:NSMakeRect(18, 150, 660, 48) size:13 bold:NO]];

    item.view = v;
    [self.tabs addTabViewItem:item];
}

- (NSTextField *)label:(NSString *)text frame:(NSRect)frame size:(CGFloat)size bold:(BOOL)bold {
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    label.stringValue = text;
    label.editable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.font = bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
    return label;
}

- (NSTextField *)field:(NSString *)text frame:(NSRect)frame {
    NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
    field.stringValue = text;
    return field;
}

- (NSPopUpButton *)unitPopup:(NSRect)frame {
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:frame pullsDown:NO];
    [popup addItemsWithTitles:@[@"ms", @"秒"]];
    return popup;
}

- (NSButton *)button:(NSString *)title frame:(NSRect)frame action:(SEL)action {
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    button.title = title;
    button.bezelStyle = NSBezelStyleRounded;
    button.target = self;
    button.action = action;
    return button;
}

- (void)chooseTypoFile:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"选择错词库";
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    if ([panel runModal] == NSModalResponseOK) self.typoField.stringValue = panel.URL.path ?: @"";
}

- (void)saveTypoDoc:(id)sender {
    NSMutableArray *lines = [NSMutableArray array];
    NSInteger lineNumber = 0;
    for (NSString *raw in [self.wordsView.string componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        lineNumber++;
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!line.length) continue;
        NSArray *parts = [line componentsSeparatedByString:@"=>"];
        NSString *correct = parts.count == 2 ? [parts[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : @"";
        NSString *wrong = parts.count == 2 ? [parts[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : @"";
        if (parts.count != 2 || !correct.length || !wrong.length) {
            self.statusField.stringValue = [NSString stringWithFormat:@"第 %ld 行格式错误：请使用 原词=>错词", (long)lineNumber];
            return;
        }
        [lines addObject:[NSString stringWithFormat:@"%@=>%@", wrong, correct]];
    }
    if (!lines.count) {
        self.statusField.stringValue = @"没有可生成的错词规则";
        return;
    }

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"typos.txt";
    if ([panel runModal] != NSModalResponseOK) return;

    NSString *out = [lines componentsJoinedByString:@"\n"];
    NSError *error = nil;
    if (![out writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        self.statusField.stringValue = [@"生成失败：" stringByAppendingString:error.localizedDescription];
        return;
    }
    self.typoField.stringValue = panel.URL.path ?: @"";
    self.statusField.stringValue = @"错词库已生成";
}

- (NSString *)durationArg:(NSTextField *)field unit:(NSPopUpButton *)unit {
    double seconds = field.doubleValue * ([unit.titleOfSelectedItem isEqualToString:@"秒"] ? 1 : 0.001);
    return [NSString stringWithFormat:@"%lldns", (long long)llround(seconds * 1000000000)];
}

- (void)startTyping:(id)sender {
    if (self.task) return;
    self.startPending = NO;
    self.startGeneration++;
    if (![self validateSettings]) return;
    [self saveSettings];
    self.startPending = NO;
    self.taskPaused = NO;
    if (self.task && self.task.isRunning) return;
    if (!CGPreflightPostEventAccess()) {
        NSString *message = @"Mac Typer 尚未获得辅助功能权限。请在设置页点“测试辅助功能权限”，只需给 Mac Typer 授权一次。";
        self.statusField.stringValue = message;
        [self showError:message];
        return;
    }
    NSString *text = self.textView.string ?: @"";
    if (![[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length]) {
        self.statusField.stringValue = @"请输入内容";
        return;
    }

    NSURL *tool = [[NSBundle mainBundle] URLForResource:@"mac-typer" withExtension:nil];
    self.task = [[NSTask alloc] init];
    self.task.executableURL = tool;
    NSMutableArray *args = [NSMutableArray arrayWithObjects:@"-event-stream", @"-s", text, @"-delay", [self durationArg:self.delayField unit:self.delayUnit], @"-jitter", [self durationArg:self.jitterField unit:self.jitterUnit], @"-countdown", [NSString stringWithFormat:@"%ld", (long)self.countdownField.doubleValue], nil];
    if (self.typoField.stringValue.length > 0) [args addObjectsFromArray:@[@"-typos", self.typoField.stringValue]];
    self.task.arguments = args;

    NSPipe *pipe = [NSPipe pipe];
    self.task.standardError = pipe;
    NSPipe *eventsPipe = [NSPipe pipe];
    self.task.standardOutput = eventsPipe;
    NSFileHandle *eventReader = eventsPipe.fileHandleForReading;
    self.eventReader = eventReader;
    __block NSMutableData *eventBuffer = [NSMutableData data];
    __weak AppDelegate *weakSelf = self;
    eventReader.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (!data.length) {
            handle.readabilityHandler = nil;
            return;
        }
        [eventBuffer appendData:data];
        NSData *newline = [@"\n" dataUsingEncoding:NSUTF8StringEncoding];
        NSRange range;
        while ((range = [eventBuffer rangeOfData:newline options:0 range:NSMakeRange(0, eventBuffer.length)]).location != NSNotFound) {
            NSData *lineData = [eventBuffer subdataWithRange:NSMakeRange(0, range.location)];
            [eventBuffer replaceBytesInRange:NSMakeRange(0, NSMaxRange(range)) withBytes:NULL length:0];
            NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
            if (line) [weakSelf handleEventLine:line];
        }
    };
    self.task.terminationHandler = ^(NSTask *finished) {
        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        NSString *message = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate *strongSelf = weakSelf;
            strongSelf.startButton.enabled = YES;
            strongSelf.taskPaused = NO;
            strongSelf.statusField.stringValue = finished.terminationStatus == 0 ? @"完成" : (message.length ? message : @"已结束");
            if (finished.terminationStatus != 0 && message.length) [strongSelf showError:message];
            strongSelf.task = nil;
        });
    };

    NSError *error = nil;
    self.startButton.enabled = NO;
    @synchronized (self) { self.acceptingEvents = YES; }
    self.statusField.stringValue = @"倒计时开始后，请把光标放到目标输入框";
    if (![self.task launchAndReturnError:&error]) {
        @synchronized (self) { self.acceptingEvents = NO; }
        eventReader.readabilityHandler = nil;
        [eventReader closeFile];
        self.eventReader = nil;
        self.startButton.enabled = YES;
        self.statusField.stringValue = error.localizedDescription;
        [self showError:error.localizedDescription];
        self.task = nil;
    }
}

- (void)showError:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"执行失败";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"好"];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)togglePause:(id)sender {
    if (!self.task.isRunning) {
        self.statusField.stringValue = self.startPending ? @"任务仍在等待启动，暂时不能暂停" : @"没有正在执行的任务";
        return;
    }
    if (kill(self.task.processIdentifier, self.taskPaused ? SIGCONT : SIGSTOP) != 0) {
        self.statusField.stringValue = @"暂停失败：任务已经结束";
        return;
    }
    self.taskPaused = !self.taskPaused;
    self.statusField.stringValue = self.taskPaused ? @"已暂停" : @"继续输入";
}

- (void)stopTyping:(id)sender {
    @synchronized (self) { self.acceptingEvents = NO; }
    self.startGeneration++;
    BOOL wasPending = self.startPending;
    self.startPending = NO;
    self.taskPaused = NO;
    if (!self.task.isRunning) {
        self.statusField.stringValue = wasPending ? @"已取消启动" : @"没有正在执行的任务";
        return;
    }
    kill(self.task.processIdentifier, SIGCONT);
    [self.task terminate];
    self.eventReader.readabilityHandler = nil;
    self.statusField.stringValue = @"正在结束";
}

- (void)testPermission:(id)sender {
    BOOL ok = CGPreflightPostEventAccess();
    if (!ok) ok = CGRequestPostEventAccess();
    self.statusField.stringValue = ok ? @"辅助功能权限已放行，只需授权一次" : @"未放行：请按教程只为 Mac Typer 打开权限";
}

- (void)handleEventLine:(NSString *)line {
    @synchronized (self) {
    if (!self.acceptingEvents) return;
    if ([line hasPrefix:@"T"]) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:[line substringFromIndex:1] options:0];
        NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (text) [self postText:text];
    } else if ([line hasPrefix:@"B"]) {
        NSInteger count = [[line substringFromIndex:1] integerValue];
        if (count > 0 && count < 10000) [self postBackspaces:count];
    }
    }
}

- (void)postText:(NSString *)text {
    NSUInteger length = text.length;
    if (!length) return;
    UniChar *chars = malloc(sizeof(UniChar) * length);
    if (!chars) return;
    [text getCharacters:chars range:NSMakeRange(0, length)];
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, 0, true);
    CGEventRef up = CGEventCreateKeyboardEvent(NULL, 0, false);
    if (down && up) {
        CGEventKeyboardSetUnicodeString(down, length, chars);
        CGEventKeyboardSetUnicodeString(up, length, chars);
        CGEventPost(kCGHIDEventTap, down);
        CGEventPost(kCGHIDEventTap, up);
    }
    if (down) CFRelease(down);
    if (up) CFRelease(up);
    free(chars);
}

- (void)postBackspaces:(NSInteger)count {
    for (NSInteger i = 0; i < count; i++) {
        CGEventRef down = CGEventCreateKeyboardEvent(NULL, 51, true);
        CGEventRef up = CGEventCreateKeyboardEvent(NULL, 51, false);
        if (down) CGEventPost(kCGHIDEventTap, down);
        if (up) CGEventPost(kCGHIDEventTap, up);
        if (down) CFRelease(down);
        if (up) CFRelease(up);
    }
}

- (void)recordStartHotkey:(id)sender {
    if (self.task || self.startPending) return;
    [self unregisterHotkeys];
    self.recordingAction = @"start";
    self.statusField.stringValue = @"请按下新的开始快捷键";
}

- (void)recordPauseHotkey:(id)sender {
    if (self.task || self.startPending) return;
    [self unregisterHotkeys];
    self.recordingAction = @"pause";
    self.statusField.stringValue = @"请按下新的暂停快捷键";
}

- (void)recordStopHotkey:(id)sender {
    if (self.task || self.startPending) return;
    [self unregisterHotkeys];
    self.recordingAction = @"stop";
    self.statusField.stringValue = @"请按下新的结束快捷键";
}

- (void)installHotkeyMonitor {
    EventTypeSpec type = {kEventClassKeyboard, kEventHotKeyPressed};
    OSStatus status = InstallEventHandler(GetApplicationEventTarget(), MacTyperHotkeyHandler, 1, &type,
                                          (__bridge void *)self, &_hotkeyHandler);
    if (status != noErr) {
        self.statusField.stringValue = @"快捷键服务启动失败，请重新打开 Mac Typer";
        return;
    }
    [self registerHotkeys];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        return [self recordHotkeyEvent:event] ? nil : event;
    }];
}

- (BOOL)recordHotkeyEvent:(NSEvent *)event {
    if (!self.recordingAction) return NO;
    if (event.keyCode == 53) {
        self.recordingAction = nil;
        [self registerHotkeys];
        self.statusField.stringValue = @"已取消快捷键录制";
        return YES;
    }
    NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (!(mods & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl))) {
        self.statusField.stringValue = @"快捷键至少要包含 Command、Option 或 Control";
        return YES;
    }

    NSString *action = self.recordingAction;
    NSString *name = [self hotkeyName:event];
    NSUInteger oldCode;
    NSEventModifierFlags oldMods;
    NSString *oldName;
    if ([action isEqualToString:@"start"]) {
        oldCode = self.startHotkeyCode;
        oldMods = self.startHotkeyMods;
        oldName = self.startHotkeyField.stringValue;
        self.startHotkeyCode = event.keyCode;
        self.startHotkeyMods = mods;
        self.startHotkeyField.stringValue = name;
    } else if ([action isEqualToString:@"pause"]) {
        oldCode = self.pauseHotkeyCode;
        oldMods = self.pauseHotkeyMods;
        oldName = self.pauseHotkeyField.stringValue;
        self.pauseHotkeyCode = event.keyCode;
        self.pauseHotkeyMods = mods;
        self.pauseHotkeyField.stringValue = name;
    } else {
        oldCode = self.stopHotkeyCode;
        oldMods = self.stopHotkeyMods;
        oldName = self.stopHotkeyField.stringValue;
        self.stopHotkeyCode = event.keyCode;
        self.stopHotkeyMods = mods;
        self.stopHotkeyField.stringValue = name;
    }
    self.recordingAction = nil;
    if (![self registerHotkeys]) {
        if ([action isEqualToString:@"start"]) {
            self.startHotkeyCode = oldCode;
            self.startHotkeyMods = oldMods;
            self.startHotkeyField.stringValue = oldName;
        } else if ([action isEqualToString:@"pause"]) {
            self.pauseHotkeyCode = oldCode;
            self.pauseHotkeyMods = oldMods;
            self.pauseHotkeyField.stringValue = oldName;
        } else {
            self.stopHotkeyCode = oldCode;
            self.stopHotkeyMods = oldMods;
            self.stopHotkeyField.stringValue = oldName;
        }
        [self registerHotkeys];
        self.statusField.stringValue = @"快捷键不可用，已恢复原设置";
    }
    return YES;
}

- (UInt32)carbonModifiers:(NSEventModifierFlags)mods {
    UInt32 result = 0;
    if (mods & NSEventModifierFlagCommand) result |= cmdKey;
    if (mods & NSEventModifierFlagOption) result |= optionKey;
    if (mods & NSEventModifierFlagControl) result |= controlKey;
    if (mods & NSEventModifierFlagShift) result |= shiftKey;
    return result;
}

- (void)unregisterHotkeys {
    if (self.startHotkey) UnregisterEventHotKey(self.startHotkey);
    if (self.pauseHotkey) UnregisterEventHotKey(self.pauseHotkey);
    if (self.stopHotkey) UnregisterEventHotKey(self.stopHotkey);
    self.startHotkey = self.pauseHotkey = self.stopHotkey = NULL;
}

- (BOOL)registerHotkeys {
    [self unregisterHotkeys];
    EventHotKeyID startID = {'MTYP', 1};
    EventHotKeyID pauseID = {'MTYP', 2};
    EventHotKeyID stopID = {'MTYP', 3};
    OSStatus startStatus = RegisterEventHotKey((UInt32)self.startHotkeyCode, [self carbonModifiers:self.startHotkeyMods], startID, GetApplicationEventTarget(), 0, &_startHotkey);
    OSStatus pauseStatus = RegisterEventHotKey((UInt32)self.pauseHotkeyCode, [self carbonModifiers:self.pauseHotkeyMods], pauseID, GetApplicationEventTarget(), 0, &_pauseHotkey);
    OSStatus stopStatus = RegisterEventHotKey((UInt32)self.stopHotkeyCode, [self carbonModifiers:self.stopHotkeyMods], stopID, GetApplicationEventTarget(), 0, &_stopHotkey);
    if (startStatus || pauseStatus || stopStatus) {
        [self unregisterHotkeys];
        self.statusField.stringValue = @"快捷键注册失败：快捷键可能已被系统或其他软件占用";
        return NO;
    } else {
        self.statusField.stringValue = @"快捷键已更新，后台可用";
        [self saveSettings];
        return YES;
    }
}

- (void)saveSettings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in @[@"delayField", @"jitterField", @"countdownField", @"typoField"]) {
        [defaults setObject:[[self valueForKey:key] stringValue] forKey:key];
    }
    [defaults setObject:self.delayUnit.titleOfSelectedItem forKey:@"delayUnit"];
    [defaults setObject:self.jitterUnit.titleOfSelectedItem forKey:@"jitterUnit"];
    [defaults setInteger:self.startHotkeyCode forKey:@"startHotkeyCode"];
    [defaults setInteger:self.startHotkeyMods forKey:@"startHotkeyMods"];
    [defaults setInteger:self.pauseHotkeyCode forKey:@"pauseHotkeyCode"];
    [defaults setInteger:self.pauseHotkeyMods forKey:@"pauseHotkeyMods"];
    [defaults setInteger:self.stopHotkeyCode forKey:@"stopHotkeyCode"];
    [defaults setInteger:self.stopHotkeyMods forKey:@"stopHotkeyMods"];
    [defaults setObject:self.startHotkeyField.stringValue forKey:@"startHotkeyName"];
    [defaults setObject:self.pauseHotkeyField.stringValue forKey:@"pauseHotkeyName"];
    [defaults setObject:self.stopHotkeyField.stringValue forKey:@"stopHotkeyName"];
    [defaults setDouble:self.hotkeyDelayField.doubleValue forKey:@"hotkeyDelay"];
}

- (void)handleRegisteredHotkey:(NSNumber *)hotkeyID {
    switch (hotkeyID.unsignedIntValue) {
    case 1: {
        if (self.startPending || self.task || ![self validateSettings]) return;
        NSUInteger generation = ++self.startGeneration;
        self.startPending = YES;
        self.statusField.stringValue = @"快捷键已触发，等待启动";
        double delay = self.hotkeyDelayField.doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!self.startPending || generation != self.startGeneration) return;
            [self startTyping:nil];
        });
        break;
    }
    case 2:
        [self togglePause:nil];
        break;
    case 3:
        [self stopTyping:nil];
        break;
    }
}

- (NSString *)hotkeyName:(NSEvent *)event {
    NSMutableString *s = [NSMutableString string];
    NSEventModifierFlags mods = event.modifierFlags;
    if (mods & NSEventModifierFlagControl) [s appendString:@"⌃"];
    if (mods & NSEventModifierFlagOption) [s appendString:@"⌥"];
    if (mods & NSEventModifierFlagShift) [s appendString:@"⇧"];
    if (mods & NSEventModifierFlagCommand) [s appendString:@"⌘"];
    NSString *key = event.keyCode == 36 ? @"↩" : event.charactersIgnoringModifiers.uppercaseString;
    [s appendString:key ?: @""];
    return s;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    @synchronized (self) { self.acceptingEvents = NO; }
    self.startPending = NO;
    self.eventReader.readabilityHandler = nil;
    if (self.task.isRunning) {
        kill(self.task.processIdentifier, SIGCONT);
        [self.task terminate];
        [self.task waitUntilExit];
    }
    [self saveSettings];
    [self unregisterHotkeys];
    if (self.hotkeyHandler) RemoveEventHandler(self.hotkeyHandler);
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;

        NSMenu *menuBar = [NSMenu new];
        NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:@"Mac Typer" action:nil keyEquivalent:@""];
        NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Mac Typer"];
        [appMenu addItemWithTitle:@"退出 Mac Typer" action:@selector(terminate:) keyEquivalent:@"q"];
        appMenuItem.submenu = appMenu;
        [menuBar addItem:appMenuItem];
        NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"编辑" action:nil keyEquivalent:@""];
        NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];
        [editMenu addItemWithTitle:@"撤销" action:@selector(undo:) keyEquivalent:@"z"];
        [editMenu addItemWithTitle:@"剪切" action:@selector(cut:) keyEquivalent:@"x"];
        [editMenu addItemWithTitle:@"复制" action:@selector(copy:) keyEquivalent:@"c"];
        [editMenu addItemWithTitle:@"粘贴" action:@selector(paste:) keyEquivalent:@"v"];
        [editMenu addItemWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"];
        editItem.submenu = editMenu;
        [menuBar addItem:editItem];
        app.mainMenu = menuBar;

        [app run];
    }
    return 0;
}
