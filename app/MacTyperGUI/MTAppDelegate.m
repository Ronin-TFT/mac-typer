#import "MTAppDelegate.h"
#import <ApplicationServices/ApplicationServices.h>
#import <math.h>
#import "MTDropTextView.h"
#import "MTHotkeys.h"
#import "MTUtil.h"

static NSString *const MTSecondsUnit = @"秒";

#pragma mark - 布局辅助

static NSTextField *MTLabel(NSString *text, CGFloat size, BOOL bold) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
    return label;
}

static NSTextField *MTField(NSString *text, CGFloat width) {
    NSTextField *field = [NSTextField textFieldWithString:text];
    [field.widthAnchor constraintEqualToConstant:width].active = YES;
    return field;
}

static NSStackView *MTRow(NSArray<NSView *> *views, CGFloat spacing) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = NSLayoutAttributeCenterY;
    stack.spacing = spacing;
    return stack;
}

static NSStackView *MTColumn(NSArray<NSView *> *views, CGFloat spacing) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.distribution = NSStackViewDistributionFill;
    stack.spacing = spacing;
    return stack;
}

static void MTFillWidth(NSStackView *stack, NSArray<NSView *> *views) {
    for (NSView *view in views) [view.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
}

static void MTPin(NSView *child, NSView *parent, CGFloat inset) {
    child.translatesAutoresizingMaskIntoConstraints = NO;
    [parent addSubview:child];
    [NSLayoutConstraint activateConstraints:@[
        [child.topAnchor constraintEqualToAnchor:parent.topAnchor constant:inset],
        [child.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor constant:inset],
        [child.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor constant:-inset],
        [child.bottomAnchor constraintEqualToAnchor:parent.bottomAnchor constant:-inset],
    ]];
}

@interface MTAppDelegate ()
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSTabView *tabs;
@property (nonatomic, strong) MTDropTextView *textView;
@property (nonatomic, strong) NSTextView *wordsView;
@property (nonatomic, strong) NSTextField *typoField;
@property (nonatomic, strong) NSTextField *delayField;
@property (nonatomic, strong) NSPopUpButton *delayUnit;
@property (nonatomic, strong) NSTextField *jitterField;
@property (nonatomic, strong) NSPopUpButton *jitterUnit;
@property (nonatomic, strong) NSTextField *countdownField;
@property (nonatomic, strong) NSTextField *typoRateField;
@property (nonatomic, strong) NSTextField *slipRateField;
@property (nonatomic, strong) NSButton *naturalCheckbox;
@property (nonatomic, strong) NSArray<NSTextField *> *hotkeyFields;
@property (nonatomic, strong) NSTextField *hotkeyDelayField;
@property (nonatomic, strong) NSButton *keepInMenuBarCheckbox;
@property (nonatomic, strong) NSTextField *statusField;
@property (nonatomic, strong) NSProgressIndicator *progressBar;
@property (nonatomic, strong) NSButton *startButton;
@property (nonatomic, strong) NSButton *pauseButton;
@property (nonatomic, strong) NSButton *stopButton;
@property (nonatomic, strong) NSStatusItem *statusItem;

@property (nonatomic, strong) MTHotkeyCenter *hotkeyCenter;
@property (nonatomic, strong) NSMutableArray<MTHotkey *> *hotkeys;
@property (nonatomic) NSUInteger recordingAction;
@property (nonatomic, strong, nullable) id localKeyMonitor;

@property (nonatomic) BOOL startPending;
@property (nonatomic) NSUInteger startGeneration;
@property (nonatomic, strong, nullable) NSDate *typingStartedAt;
@property (nonatomic, strong, nullable) NSDate *pausedAt;
@property (nonatomic) NSTimeInterval pausedDuration;
@end

@implementation MTAppDelegate

- (instancetype)init {
    if ((self = [super init])) {
        _engine = [MTEngine new];
        _engine.delegate = self;
        _keepInMenuBar = YES;
    }
    return self;
}

#pragma mark - 启动与退出

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self loadHotkeys];
    [self buildWindow];
    [self loadSettings];
    [self buildStatusItem];

    self.hotkeyCenter = [MTHotkeyCenter new];
    __weak MTAppDelegate *weakSelf = self;
    self.hotkeyCenter.handler = ^(MTHotkeyAction action) { [weakSelf handleHotkey:action]; };
    if ([self.hotkeyCenter install]) {
        [self applyHotkeys];
    } else {
        self.statusField.stringValue = @"快捷键服务启动失败，请重新打开 Mac Typer";
    }
    self.localKeyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        return [weakSelf recordHotkeyEvent:event] ? nil : event;
    }];

    [self updateControls];
    [self showMainWindow:nil];
    if (!CGPreflightPostEventAccess()) {
        self.statusField.stringValue = @"尚未获得辅助功能权限：请到“设置”页点“测试辅助功能权限”";
    }
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app { return YES; }

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app {
    return !self.keepInMenuBar;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible {
    if (!visible) [self showMainWindow:nil];
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    self.startPending = NO;
    self.startGeneration++;
    [self.engine stop];
    [self saveSettings];
    [self.hotkeyCenter uninstall];
    if (self.localKeyMonitor) [NSEvent removeMonitor:self.localKeyMonitor];
}

- (void)windowWillClose:(NSNotification *)notification {
    // 保留在菜单栏时隐藏 Dock 图标；快捷键和菜单栏菜单继续可用。
    if (self.keepInMenuBar) [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

- (void)showMainWindow:(id)sender {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

#pragma mark - 窗口

- (void)buildWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 640)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                        NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"Mac Typer";
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    self.window.contentMinSize = NSMakeSize(760, 560);
    [self.window center];
    [self.window setFrameAutosaveName:@"MacTyperMainWindow"];

    NSView *content = self.window.contentView;
    NSTextField *subtitle = MTLabel(@"模拟键入 · 自然节奏 · 错词与手误", 13, NO);
    subtitle.textColor = NSColor.secondaryLabelColor;
    NSStackView *header = MTColumn(@[MTLabel(@"Mac Typer", 24, YES), subtitle], 2);

    self.tabs = [NSTabView new];
    [self.tabs addTabViewItem:[self mainTab]];
    [self.tabs addTabViewItem:[self typoToolTab]];
    [self.tabs addTabViewItem:[self settingsTab]];

    self.statusField = MTLabel(@"准备就绪", 13, NO);
    self.statusField.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.statusField setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                               forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.progressBar = [NSProgressIndicator new];
    self.progressBar.style = NSProgressIndicatorStyleBar;
    self.progressBar.indeterminate = NO;
    self.progressBar.minValue = 0;
    self.progressBar.maxValue = 1;
    self.progressBar.hidden = YES;
    NSStackView *statusStack = MTColumn(@[self.statusField, self.progressBar], 4);
    MTFillWidth(statusStack, @[self.statusField, self.progressBar]);
    [statusStack setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.startButton = [NSButton buttonWithTitle:@"开始" target:self action:@selector(startTyping:)];
    self.pauseButton = [NSButton buttonWithTitle:@"暂停" target:self action:@selector(togglePause:)];
    self.stopButton = [NSButton buttonWithTitle:@"结束" target:self action:@selector(stopTyping:)];
    for (NSButton *button in @[self.startButton, self.pauseButton, self.stopButton]) {
        [button.widthAnchor constraintGreaterThanOrEqualToConstant:84].active = YES;
    }
    NSStackView *footer = MTRow(@[statusStack, self.startButton, self.pauseButton, self.stopButton], 8);

    for (NSView *view in @[header, self.tabs, footer]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
        [header.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [header.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-24],
        [self.tabs.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:8],
        [self.tabs.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [self.tabs.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [footer.topAnchor constraintEqualToAnchor:self.tabs.bottomAnchor constant:12],
        [footer.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [footer.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [footer.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16],
    ]];
}

- (NSScrollView *)scrollViewWithTextView:(NSTextView *)textView {
    NSScrollView *scroll = [NSScrollView new];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSBezelBorder;
    textView.minSize = NSMakeSize(0, 0);
    textView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    textView.verticallyResizable = YES;
    textView.horizontallyResizable = NO;
    textView.autoresizingMask = NSViewWidthSizable;
    textView.textContainer.containerSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    textView.textContainer.widthTracksTextView = YES;
    textView.richText = NO;
    textView.allowsUndo = YES;
    // 关闭自动替换，避免引号、破折号或拼写被改掉后输入的内容与原文不一致。
    textView.automaticQuoteSubstitutionEnabled = NO;
    textView.automaticDashSubstitutionEnabled = NO;
    textView.automaticTextReplacementEnabled = NO;
    textView.automaticSpellingCorrectionEnabled = NO;
    textView.font = [NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular];
    scroll.documentView = textView;
    [scroll setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    [scroll.heightAnchor constraintGreaterThanOrEqualToConstant:140].active = YES;
    return scroll;
}

- (NSTabViewItem *)mainTab {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"main"];
    item.label = @"输入";

    NSTextField *hint = MTLabel(@"可直接拖入文本文件", 12, NO);
    hint.textColor = NSColor.secondaryLabelColor;
    NSStackView *top = MTRow(@[], 8);
    [top addView:MTLabel(@"输入内容", 14, YES) inGravity:NSStackViewGravityLeading];
    [top addView:hint inGravity:NSStackViewGravityLeading];
    [top addView:[NSButton buttonWithTitle:@"导入文本…" target:self action:@selector(importText:)] inGravity:NSStackViewGravityTrailing];

    self.textView = [[MTDropTextView alloc] initWithFrame:NSMakeRect(0, 0, 600, 200)];
    self.textView.string = @"this is the address";
    __weak MTAppDelegate *weakSelf = self;
    self.textView.importHandler = ^(NSURL *url, NSError *error) { [weakSelf didImportURL:url error:error]; };
    NSScrollView *scroll = [self scrollViewWithTextView:self.textView];

    self.typoField = [NSTextField textFieldWithString:@""];
    self.typoField.placeholderString = @"错词库路径，可留空";
    [self.typoField setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *typoRow = MTRow(@[self.typoField,
                                   [NSButton buttonWithTitle:@"选择错词库…" target:self action:@selector(chooseTypoFile:)]], 8);

    self.delayField = MTField(@"80", 72);
    self.delayUnit = [self unitPopup];
    self.jitterField = MTField(@"60", 72);
    self.jitterUnit = [self unitPopup];
    self.countdownField = MTField(@"5", 72);
    self.typoRateField = MTField(@"100", 72);
    self.slipRateField = MTField(@"0", 72);
    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[MTLabel(@"基础间隔", 13, NO), MTLabel(@"随机抖动", 13, NO), MTLabel(@"倒计时秒", 13, NO),
          MTLabel(@"错词概率 %", 13, NO), MTLabel(@"手误概率 %", 13, NO)],
        @[MTRow(@[self.delayField, self.delayUnit], 4), MTRow(@[self.jitterField, self.jitterUnit], 4),
          self.countdownField, self.typoRateField, self.slipRateField],
    ]];
    grid.columnSpacing = 24;
    grid.rowSpacing = 6;

    self.naturalCheckbox = [NSButton checkboxWithTitle:@"自然节奏：标点和换行后停顿更久、词内连击更快、偶尔犹豫"
                                                target:nil action:nil];
    NSTextField *slipHint = MTLabel(@"手误：英文字母按概率误按相邻键（有时多打一个字母才发现），随后删除并改正。", 12, NO);
    slipHint.textColor = NSColor.secondaryLabelColor;

    NSStackView *stack = MTColumn(@[top, scroll, typoRow, grid, self.naturalCheckbox, slipHint], 10);
    MTFillWidth(stack, @[top, scroll, typoRow]);
    for (NSView *view in @[top, typoRow, grid, self.naturalCheckbox, slipHint]) {
        [view setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationVertical];
    }
    item.view = [NSView new];
    MTPin(stack, item.view, 16);
    return item;
}

- (NSTabViewItem *)typoToolTab {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"typos"];
    item.label = @"错词库工具";
    NSTextField *title = MTLabel(@"每行写：原词=>错词，例如 mother=>motter；# 开头为注释", 14, YES);
    self.wordsView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 600, 300)];
    self.wordsView.string = @"mother=>motter\naddress=>adress\nthe=>teh";
    NSScrollView *scroll = [self scrollViewWithTextView:self.wordsView];
    NSButton *save = [NSButton buttonWithTitle:@"生成错词库文档…" target:self action:@selector(saveTypoDoc:)];
    NSStackView *stack = MTColumn(@[title, scroll, save], 10);
    MTFillWidth(stack, @[scroll]);
    item.view = [NSView new];
    MTPin(stack, item.view, 16);
    return item;
}

- (NSTabViewItem *)settingsTab {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"settings"];
    item.label = @"设置";

    NSMutableArray<NSArray<NSView *> *> *rows = [NSMutableArray array];
    NSMutableArray<NSTextField *> *fields = [NSMutableArray array];
    NSArray<NSString *> *names = @[@"开始", @"暂停/继续", @"结束"];
    for (NSUInteger i = 0; i < names.count; i++) {
        NSTextField *field = MTField(@"", 120);
        field.editable = NO;
        field.selectable = NO;
        [fields addObject:field];
        NSButton *record = [NSButton buttonWithTitle:@"录制" target:self action:@selector(recordHotkey:)];
        record.tag = (NSInteger)(i + 1);
        [rows addObject:@[MTLabel(names[i], 13, NO), field, record]];
    }
    self.hotkeyFields = fields;
    NSGridView *hotkeyGrid = [NSGridView gridViewWithViews:rows];
    hotkeyGrid.columnSpacing = 12;
    hotkeyGrid.rowSpacing = 8;

    self.hotkeyDelayField = MTField(@"0", 90);
    self.keepInMenuBarCheckbox = [NSButton checkboxWithTitle:@"关闭窗口后保留在菜单栏（快捷键继续可用）"
                                                      target:self action:@selector(keepInMenuBarChanged:)];
    NSTextField *tutorial = [NSTextField wrappingLabelWithString:
        @"教程：系统设置 > 隐私与安全性 > 辅助功能，打开 Mac Typer。快捷键在后台也能使用；按 Esc 取消录制，执行期间不能录制。"];

    NSStackView *stack = MTColumn(@[
        MTLabel(@"快捷键", 14, YES), hotkeyGrid,
        MTLabel(@"快捷键启动延迟（秒）", 14, YES), self.hotkeyDelayField,
        self.keepInMenuBarCheckbox,
        [NSButton buttonWithTitle:@"测试辅助功能权限" target:self action:@selector(testPermission:)],
        tutorial,
    ], 10);
    [stack setCustomSpacing:20 afterView:hotkeyGrid];
    [stack setCustomSpacing:20 afterView:self.hotkeyDelayField];
    MTFillWidth(stack, @[tutorial]);
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    [stack addArrangedSubview:spacer];
    item.view = [NSView new];
    MTPin(stack, item.view, 16);
    return item;
}

- (NSPopUpButton *)unitPopup {
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [popup addItemsWithTitles:@[@"ms", MTSecondsUnit]];
    return popup;
}

- (void)buildStatusItem {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSImage *image = [NSImage imageWithSystemSymbolName:@"keyboard" accessibilityDescription:@"Mac Typer"];
    if (image) {
        image.template = YES;
        self.statusItem.button.image = image;
    } else {
        self.statusItem.button.title = @"⌨";
    }
    NSMenu *menu = [NSMenu new];
    [menu addItemWithTitle:@"显示主窗口" action:@selector(showMainWindow:) keyEquivalent:@""].target = self;
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"开始" action:@selector(startTyping:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"暂停" action:@selector(togglePause:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"结束" action:@selector(stopTyping:) keyEquivalent:@""].target = self;
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"退出 Mac Typer" action:@selector(terminate:) keyEquivalent:@""].target = NSApp;
    self.statusItem.menu = menu;
    self.statusItem.visible = self.keepInMenuBar;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL action = item.action;
    if (action == @selector(startTyping:)) return !self.engine.running && !self.startPending;
    if (action == @selector(togglePause:)) {
        item.title = self.engine.paused ? @"继续" : @"暂停";
        return self.engine.running && !self.engine.stopping;
    }
    if (action == @selector(stopTyping:)) return self.engine.running || self.startPending;
    return YES;
}

- (void)updateControls {
    BOOL running = self.engine.running;
    self.startButton.enabled = !running && !self.startPending;
    self.pauseButton.enabled = running && !self.engine.stopping;
    self.pauseButton.title = self.engine.paused ? @"继续" : @"暂停";
    self.stopButton.enabled = running || self.startPending;
}

- (void)showError:(NSString *)message {
    if (!self.window.isVisible) [self showMainWindow:nil];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"执行失败";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"好"];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

#pragma mark - 设置

- (BOOL)readConfig:(MTConfig *)config {
    BOOL delaySeconds = [self.delayUnit.titleOfSelectedItem isEqualToString:MTSecondsUnit];
    BOOL jitterSeconds = [self.jitterUnit.titleOfSelectedItem isEqualToString:MTSecondsUnit];
    double delay, jitter, countdown, typoRate, slipRate;
    if (!MTParseNumber(self.delayField.stringValue, delaySeconds ? 60 : 60000, NO, &delay) ||
        !MTParseNumber(self.jitterField.stringValue, jitterSeconds ? 60 : 60000, NO, &jitter) ||
        !MTParseNumber(self.countdownField.stringValue, 3600, YES, &countdown) ||
        !MTParseNumber(self.typoRateField.stringValue, 100, NO, &typoRate) ||
        !MTParseNumber(self.slipRateField.stringValue, 100, NO, &slipRate)) {
        [self showError:@"间隔和抖动须为 0–60 秒；倒计时须为 0–3600 的整数；错词和手误概率须为 0–100%。"];
        return NO;
    }
    memset(config, 0, sizeof *config);
    config->delay_ns = llround(delay * (delaySeconds ? 1e9 : 1e6));
    config->jitter_ns = llround(jitter * (jitterSeconds ? 1e9 : 1e6));
    config->countdown = (int)countdown;
    config->typo_rate = typoRate / 100.0;
    config->slip_rate = slipRate / 100.0;
    config->natural = self.naturalCheckbox.state == NSControlStateValueOn;
    return YES;
}

- (NSArray<NSString *> *)textSettingKeys {
    return @[@"delayField", @"jitterField", @"countdownField", @"typoRateField", @"slipRateField", @"typoField", @"hotkeyDelayField"];
}

- (void)loadSettings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in [self textSettingKeys]) {
        NSString *value = [defaults stringForKey:key];
        if (value) [[self valueForKey:key] setStringValue:value];
    }
    if (![defaults stringForKey:@"hotkeyDelayField"] && [defaults objectForKey:@"hotkeyDelay"]) {
        self.hotkeyDelayField.stringValue = [NSString stringWithFormat:@"%g", [defaults doubleForKey:@"hotkeyDelay"]];
    }
    [self.delayUnit selectItemWithTitle:[defaults stringForKey:@"delayUnit"] ?: @"ms"];
    [self.jitterUnit selectItemWithTitle:[defaults stringForKey:@"jitterUnit"] ?: @"ms"];
    self.naturalCheckbox.state = [defaults boolForKey:@"natural"] ? NSControlStateValueOn : NSControlStateValueOff;
    if ([defaults objectForKey:@"keepInMenuBar"]) self.keepInMenuBar = [defaults boolForKey:@"keepInMenuBar"];
    self.keepInMenuBarCheckbox.state = self.keepInMenuBar ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)saveSettings {
    if (!self.delayField) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in [self textSettingKeys]) {
        [defaults setObject:[[self valueForKey:key] stringValue] forKey:key];
    }
    [defaults setObject:self.delayUnit.titleOfSelectedItem forKey:@"delayUnit"];
    [defaults setObject:self.jitterUnit.titleOfSelectedItem forKey:@"jitterUnit"];
    [defaults setBool:self.naturalCheckbox.state == NSControlStateValueOn forKey:@"natural"];
    [defaults setBool:self.keepInMenuBar forKey:@"keepInMenuBar"];
    NSArray<NSString *> *prefixes = @[@"start", @"pause", @"stop"];
    for (NSUInteger i = 0; i < self.hotkeys.count; i++) {
        MTHotkey *hotkey = self.hotkeys[i];
        [defaults setInteger:(NSInteger)hotkey.keyCode forKey:[prefixes[i] stringByAppendingString:@"HotkeyCode"]];
        [defaults setInteger:(NSInteger)hotkey.modifiers forKey:[prefixes[i] stringByAppendingString:@"HotkeyMods"]];
        [defaults setObject:hotkey.displayName forKey:[prefixes[i] stringByAppendingString:@"HotkeyName"]];
    }
}

- (void)keepInMenuBarChanged:(NSButton *)sender {
    self.keepInMenuBar = sender.state == NSControlStateValueOn;
    self.statusItem.visible = self.keepInMenuBar;
    [self saveSettings];
}

- (void)testPermission:(id)sender {
    BOOL ok = CGPreflightPostEventAccess();
    if (!ok) ok = CGRequestPostEventAccess();
    self.statusField.stringValue = ok ? @"辅助功能权限已放行" : @"未放行：请按教程为 Mac Typer 打开辅助功能权限";
}

#pragma mark - 文件

- (void)chooseTypoFile:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"选择错词库";
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSModalResponseOK) self.typoField.stringValue = panel.URL.path ?: @"";
    }];
}

- (void)importText:(id)sender {
    [self showMainWindow:nil];
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"导入文本";
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) return;
        NSError *error = nil;
        NSString *text = MTReadTextFile(panel.URL, &error);
        if (text) [self.textView replaceAllText:text];
        [self didImportURL:panel.URL error:text ? nil : error];
    }];
}

- (void)didImportURL:(NSURL *)url error:(NSError *)error {
    if (error) {
        self.statusField.stringValue = [@"导入失败：" stringByAppendingString:error.localizedDescription];
        return;
    }
    [self.tabs selectTabViewItemWithIdentifier:@"main"];
    self.statusField.stringValue = [NSString stringWithFormat:@"已导入 %@（%lu 字）", url.lastPathComponent,
                                    (unsigned long)self.textView.string.length];
}

- (void)saveTypoDoc:(id)sender {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSInteger lineNumber = 0, ruleCount = 0;
    for (NSString *raw in [self.wordsView.string componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        lineNumber++;
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!line.length) continue;
        if ([line hasPrefix:@"#"]) {
            [lines addObject:line];
            continue;
        }
        NSArray<NSString *> *parts = [line componentsSeparatedByString:@"=>"];
        NSString *correct = parts.count == 2 ? [parts[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : @"";
        NSString *wrong = parts.count == 2 ? [parts[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : @"";
        if (parts.count != 2 || !correct.length || !wrong.length) {
            self.statusField.stringValue = [NSString stringWithFormat:@"第 %ld 行格式错误：请使用 原词=>错词", (long)lineNumber];
            return;
        }
        if ([correct isEqualToString:wrong]) {
            self.statusField.stringValue = [NSString stringWithFormat:@"第 %ld 行原词与错词相同", (long)lineNumber];
            return;
        }
        [lines addObject:[NSString stringWithFormat:@"%@=>%@", wrong, correct]];
        ruleCount++;
    }
    if (!ruleCount) {
        self.statusField.stringValue = @"没有可生成的错词规则";
        return;
    }
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"typos.txt";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) return;
        NSError *error = nil;
        NSString *out = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
        if (![out writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
            self.statusField.stringValue = [@"生成失败：" stringByAppendingString:error.localizedDescription];
            return;
        }
        self.typoField.stringValue = panel.URL.path ?: @"";
        self.statusField.stringValue = @"错词库已生成";
    }];
}

#pragma mark - 执行

- (void)startTyping:(id)sender {
    if (self.engine.running) return;
    self.startPending = NO;
    self.startGeneration++;
    [self updateControls];
    MTConfig config;
    if (![self readConfig:&config]) return;
    [self saveSettings];
    if (!CGPreflightPostEventAccess()) {
        NSString *message = @"Mac Typer 尚未获得辅助功能权限。请在设置页点“测试辅助功能权限”。";
        self.statusField.stringValue = message;
        [self showError:message];
        return;
    }
    NSString *text = self.textView.string ?: @"";
    if (![text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) {
        self.statusField.stringValue = @"请输入内容";
        return;
    }
    NSString *error = nil;
    if (![self.engine startWithText:text typoPath:self.typoField.stringValue config:config error:&error]) {
        self.statusField.stringValue = error ?: @"启动失败";
        [self showError:self.statusField.stringValue];
        return;
    }
    self.typingStartedAt = nil;
    self.pausedAt = nil;
    self.pausedDuration = 0;
    self.progressBar.doubleValue = 0;
    self.progressBar.hidden = NO;
    self.statusField.stringValue = config.countdown > 0 ? @"倒计时开始，请把光标放到目标输入框" : @"正在输入…";
    [self updateControls];
}

- (void)togglePause:(id)sender {
    if (!self.engine.running || self.engine.stopping) {
        self.statusField.stringValue = self.startPending ? @"任务仍在等待启动，暂时不能暂停" : @"没有正在执行的任务";
        return;
    }
    BOOL pause = !self.engine.paused;
    if (![self.engine updatePaused:pause]) {
        self.statusField.stringValue = @"暂停失败：任务已经结束";
        return;
    }
    if (pause) {
        self.pausedAt = [NSDate date];
        self.statusField.stringValue = @"已暂停";
    } else {
        if (self.pausedAt) self.pausedDuration -= self.pausedAt.timeIntervalSinceNow;
        self.pausedAt = nil;
        self.statusField.stringValue = @"继续输入";
    }
    [self updateControls];
}

- (void)stopTyping:(id)sender {
    self.startGeneration++;
    BOOL wasPending = self.startPending;
    self.startPending = NO;
    if (![self.engine stop]) {
        self.statusField.stringValue = wasPending ? @"已取消启动" : @"没有正在执行的任务";
    } else {
        self.statusField.stringValue = @"正在结束";
    }
    [self updateControls];
}

- (void)engineDidCountdown:(NSInteger)seconds {
    if (self.engine.stopping || self.engine.paused) return;
    self.statusField.stringValue = [NSString stringWithFormat:@"%ld 秒后开始，请把光标放到目标输入框", (long)seconds];
}

- (void)engineDidProgress:(NSInteger)done total:(NSInteger)total {
    if (!self.typingStartedAt) {
        // 倒计时期间的暂停不计入输入用时。
        self.typingStartedAt = [NSDate date];
        self.pausedDuration = 0;
        if (self.pausedAt) self.pausedAt = self.typingStartedAt;
    }
    self.progressBar.maxValue = MAX(total, 1);
    self.progressBar.doubleValue = done;
    if (self.engine.stopping || self.engine.paused) return;
    NSTimeInterval active = -self.typingStartedAt.timeIntervalSinceNow - self.pausedDuration;
    self.statusField.stringValue = MTProgressText(done, total, active);
}

- (void)engineDidFinish:(MTFinishReason)reason message:(NSString *)message {
    switch (reason) {
    case MTFinishReasonDone:
        self.progressBar.doubleValue = self.progressBar.maxValue;
        self.statusField.stringValue = @"完成";
        break;
    case MTFinishReasonStopped:
        self.progressBar.hidden = YES;
        self.statusField.stringValue = @"已结束";
        break;
    case MTFinishReasonError:
        self.progressBar.hidden = YES;
        self.statusField.stringValue = message ?: @"执行失败";
        [self showError:self.statusField.stringValue];
        break;
    }
    [self updateControls];
}

#pragma mark - 快捷键

- (void)loadHotkeys {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSEventModifierFlags optionCommand = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    self.hotkeys = [@[
        [[MTHotkey alloc] initWithKeyCode:11 modifiers:optionCommand displayName:@"⌥⌘B"],
        [[MTHotkey alloc] initWithKeyCode:45 modifiers:optionCommand displayName:@"⌥⌘N"],
        [[MTHotkey alloc] initWithKeyCode:46 modifiers:optionCommand displayName:@"⌥⌘M"],
    ] mutableCopy];
    NSArray<NSString *> *prefixes = @[@"start", @"pause", @"stop"];
    for (NSUInteger i = 0; i < prefixes.count; i++) {
        NSString *codeKey = [prefixes[i] stringByAppendingString:@"HotkeyCode"];
        if (![defaults objectForKey:codeKey]) continue;
        NSString *name = [defaults stringForKey:[prefixes[i] stringByAppendingString:@"HotkeyName"]] ?: self.hotkeys[i].displayName;
        self.hotkeys[i] = [[MTHotkey alloc] initWithKeyCode:(NSUInteger)[defaults integerForKey:codeKey]
                                                  modifiers:(NSEventModifierFlags)[defaults integerForKey:[prefixes[i] stringByAppendingString:@"HotkeyMods"]]
                                                displayName:name];
    }
}

- (BOOL)applyHotkeys {
    BOOL ok = [self.hotkeyCenter registerHotkeys:self.hotkeys];
    for (NSUInteger i = 0; i < self.hotkeyFields.count && i < self.hotkeys.count; i++) {
        self.hotkeyFields[i].stringValue = self.hotkeys[i].displayName;
    }
    if (ok) {
        self.statusField.stringValue = @"快捷键已更新，后台可用";
        [self saveSettings];
    } else {
        self.statusField.stringValue = @"快捷键注册失败：可能已被系统或其他软件占用";
    }
    return ok;
}

- (void)recordHotkey:(NSButton *)sender {
    if (self.engine.running || self.startPending) {
        self.statusField.stringValue = @"执行期间不能录制快捷键";
        return;
    }
    [self.hotkeyCenter unregisterAll];
    self.recordingAction = (NSUInteger)sender.tag;
    NSArray<NSString *> *names = @[@"开始", @"暂停/继续", @"结束"];
    self.statusField.stringValue = [NSString stringWithFormat:@"请按下新的%@快捷键（Esc 取消）", names[self.recordingAction - 1]];
}

- (BOOL)recordHotkeyEvent:(NSEvent *)event {
    if (!self.recordingAction) return NO;
    if (event.keyCode == 53) {
        self.recordingAction = 0;
        [self applyHotkeys];
        self.statusField.stringValue = @"已取消快捷键录制";
        return YES;
    }
    MTHotkey *hotkey = [MTHotkey hotkeyWithEvent:event];
    if (!hotkey) {
        self.statusField.stringValue = @"快捷键至少要包含 Command、Option 或 Control";
        return YES;
    }
    NSUInteger index = self.recordingAction - 1;
    MTHotkey *old = self.hotkeys[index];
    self.hotkeys[index] = hotkey;
    self.recordingAction = 0;
    if (![self applyHotkeys]) {
        self.hotkeys[index] = old;
        [self applyHotkeys];
        self.statusField.stringValue = @"快捷键不可用，已恢复原设置";
    }
    return YES;
}

- (void)handleHotkey:(MTHotkeyAction)action {
    switch (action) {
    case MTHotkeyActionStart: {
        if (self.startPending || self.engine.running) return;
        MTConfig config;
        if (![self readConfig:&config]) return;
        double delay;
        if (!MTParseNumber(self.hotkeyDelayField.stringValue, 3600, NO, &delay)) {
            [self showError:@"快捷键启动延迟须为 0–3600 秒。"];
            return;
        }
        NSUInteger generation = ++self.startGeneration;
        self.startPending = YES;
        self.statusField.stringValue = @"快捷键已触发，等待启动";
        [self updateControls];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self startAfterModifiersReleased:generation attempts:0];
        });
        break;
    }
    case MTHotkeyActionPause:
        [self togglePause:nil];
        break;
    case MTHotkeyActionStop:
        [self stopTyping:nil];
        break;
    }
}

// 等用户松开快捷键的修饰键再启动（最多等 5 秒），避免首个字符被当成快捷键。
- (void)startAfterModifiersReleased:(NSUInteger)generation attempts:(NSUInteger)attempts {
    if (!self.startPending || generation != self.startGeneration) return;
    NSEventModifierFlags held = NSEvent.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                                         NSEventModifierFlagControl | NSEventModifierFlagShift);
    if (held && attempts < 100) {
        if (attempts == 0) self.statusField.stringValue = @"请松开快捷键后开始";
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            [self startAfterModifiersReleased:generation attempts:attempts + 1];
        });
        return;
    }
    [self startTyping:nil];
}

@end
