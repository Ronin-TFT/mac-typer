#import "MTRecordingController.h"
#import "MTLayout.h"
#import "MTRegionSelector.h"
#import "MTScreenRecorder.h"
#import "MTUtil.h"

static NSString *const MTRegionTitle = @"自定义区域";

static CGDirectDisplayID MTDisplayID(NSScreen *screen) {
    return [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
}

static NSScreen *_Nullable MTScreenWithID(CGDirectDisplayID displayID) {
    for (NSScreen *screen in NSScreen.screens) {
        if (MTDisplayID(screen) == displayID) return screen;
    }
    return nil;
}

@interface MTRecordingController ()
@property (nonatomic, readwrite) NSTabViewItem *tabItem;
@property (nonatomic, strong) MTScreenRecorder *recorder;
@property (nonatomic, strong) NSPopUpButton *modePopup;
@property (nonatomic, strong) NSButton *selectRegionButton;
@property (nonatomic, strong) NSTextField *regionLabel;
@property (nonatomic, strong) NSPopUpButton *fpsPopup;
@property (nonatomic, strong) NSButton *cursorCheckbox;
@property (nonatomic, strong) NSButton *autoRecordCheckbox;
@property (nonatomic, strong) NSTextField *folderLabel;
@property (nonatomic, strong) NSButton *recordButton;
@property (nonatomic, strong) NSTextField *timeLabel;
@property (nonatomic, strong, nullable) NSWindow *borderWindow;
@property (nonatomic, strong, nullable) NSTimer *timer;
@property (nonatomic, strong) NSURL *folderURL;
@property (nonatomic, strong, nullable) NSURL *lastRecordingURL;
@property (nonatomic) NSRect region;               // 全局坐标
@property (nonatomic) CGDirectDisplayID regionDisplayID;
@property (nonatomic) BOOL startedByTyping;
@end

@implementation MTRecordingController

- (instancetype)init {
    if ((self = [super init])) {
        _recorder = [MTScreenRecorder new];
        __weak MTRecordingController *weakSelf = self;
        _recorder.unexpectedStopHandler = ^(NSURL *url, NSError *error) {
            [weakSelf didStopWithURL:url error:error prefix:@"录屏被系统中断"];
        };
        NSURL *movies = [NSFileManager.defaultManager URLsForDirectory:NSMoviesDirectory inDomains:NSUserDomainMask].firstObject;
        _folderURL = [movies ?: [NSURL fileURLWithPath:NSHomeDirectory()] URLByAppendingPathComponent:@"Mac Typer" isDirectory:YES];
        [self buildTab];
        [self loadSettings];
        [self updateControls];
    }
    return self;
}

- (BOOL)isRecording { return self.recorder.recording; }
- (BOOL)isBusy { return self.recorder.busy; }
- (BOOL)autoRecordWithTyping { return self.autoRecordCheckbox.state == NSControlStateValueOn; }

- (void)status:(NSString *)message {
    if (self.statusHandler) self.statusHandler(message);
}

#pragma mark - 界面

- (void)buildTab {
    self.tabItem = [[NSTabViewItem alloc] initWithIdentifier:@"recording"];
    self.tabItem.label = @"录屏";

    self.modePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.modePopup.target = self;
    self.modePopup.action = @selector(modeChanged:);
    [self reloadScreens];
    self.selectRegionButton = [NSButton buttonWithTitle:@"选择区域…" target:self action:@selector(selectRegion:)];
    self.regionLabel = MTLabel(@"", 12, NO);
    self.regionLabel.textColor = NSColor.secondaryLabelColor;

    self.fpsPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.fpsPopup addItemsWithTitles:@[@"30 帧/秒", @"60 帧/秒"]];
    self.fpsPopup.itemArray[0].tag = 30;
    self.fpsPopup.itemArray[1].tag = 60;

    self.cursorCheckbox = [NSButton checkboxWithTitle:@"录制鼠标指针" target:nil action:nil];
    self.cursorCheckbox.state = NSControlStateValueOn;
    self.autoRecordCheckbox = [NSButton checkboxWithTitle:@"键入时自动录屏：开始输入时开始录制，完成或结束后自动停止"
                                                   target:nil action:nil];

    self.folderLabel = MTLabel(@"", 12, NO);
    self.folderLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.folderLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                               forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *folderRow = MTRow(@[MTLabel(@"保存到", 13, NO), self.folderLabel,
                                     [NSButton buttonWithTitle:@"更改…" target:self action:@selector(chooseFolder:)],
                                     [NSButton buttonWithTitle:@"在 Finder 中显示" target:self action:@selector(revealInFinder:)]], 8);

    self.recordButton = [NSButton buttonWithTitle:@"开始录屏" target:self action:@selector(toggleRecording:)];
    [self.recordButton.widthAnchor constraintGreaterThanOrEqualToConstant:110].active = YES;
    self.timeLabel = [NSTextField labelWithString:@""];
    self.timeLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];

    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[MTLabel(@"录制范围", 13, NO), MTRow(@[self.modePopup, self.selectRegionButton], 8)],
        @[NSGridCell.emptyContentView, self.regionLabel],
        @[MTLabel(@"帧率", 13, NO), self.fpsPopup],
    ]];
    grid.rowSpacing = 8;
    grid.columnSpacing = 12;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;

    NSTextField *hint = [NSTextField wrappingLabelWithString:
        @"录像里不会出现 Mac Typer 自己的窗口和选区边框。首次录屏需要在 系统设置 > 隐私与安全性 > 屏幕与系统录音 中允许 Mac Typer，然后重新打开 App。"];
    hint.textColor = NSColor.secondaryLabelColor;
    hint.font = [NSFont systemFontOfSize:12];

    NSStackView *stack = MTColumn(@[
        MTLabel(@"屏幕录制", 14, YES), grid, self.cursorCheckbox, self.autoRecordCheckbox, folderRow,
        MTRow(@[self.recordButton, self.timeLabel], 12), hint,
    ], 12);
    MTFillWidth(stack, @[folderRow, hint]);
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    [stack addArrangedSubview:spacer];
    self.tabItem.view = [NSView new];
    MTPin(stack, self.tabItem.view, 16);
}

- (void)reloadScreens {
    NSString *selected = self.modePopup.titleOfSelectedItem;
    CGDirectDisplayID selectedID = (CGDirectDisplayID)self.modePopup.selectedItem.tag;
    [self.modePopup removeAllItems];
    for (NSScreen *screen in NSScreen.screens) {
        NSString *title = [NSString stringWithFormat:@"整个屏幕：%@", screen.localizedName];
        [self.modePopup addItemWithTitle:title];
        self.modePopup.lastItem.tag = MTDisplayID(screen);
    }
    [self.modePopup addItemWithTitle:MTRegionTitle];
    self.modePopup.lastItem.tag = 0;
    if ([selected isEqualToString:MTRegionTitle]) {
        [self.modePopup selectItemWithTitle:MTRegionTitle];
    } else if (selectedID) {
        [self.modePopup selectItemWithTag:selectedID];
    }
}

- (BOOL)regionMode {
    return [self.modePopup.titleOfSelectedItem isEqualToString:MTRegionTitle];
}

- (void)modeChanged:(id)sender {
    [self updateControls];
    [self saveSettings];
}

- (void)updateControls {
    BOOL recording = self.recorder.recording, busy = self.recorder.busy;
    self.recordButton.title = recording ? @"停止录屏" : @"开始录屏";
    self.recordButton.enabled = !busy;
    for (NSControl *control in @[self.modePopup, self.selectRegionButton, self.fpsPopup, self.cursorCheckbox]) {
        control.enabled = !recording && !busy;
    }
    self.selectRegionButton.hidden = ![self regionMode];
    self.regionLabel.hidden = ![self regionMode];
    NSScreen *screen = MTScreenWithID(self.regionDisplayID);
    if (NSIsEmptyRect(self.region) || !screen) {
        self.regionLabel.stringValue = @"尚未选择区域：点“选择区域…”后在屏幕上拖拽";
    } else {
        self.regionLabel.stringValue = [NSString stringWithFormat:@"%.0f × %.0f，位于 %@",
                                        self.region.size.width, self.region.size.height, screen.localizedName];
    }
    self.folderLabel.stringValue = self.folderURL.path;
    if (!recording) self.timeLabel.stringValue = @"";
}

#pragma mark - 设置

- (void)loadSettings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *mode = [defaults stringForKey:@"recordMode"];
    if ([mode isEqualToString:@"region"]) {
        [self.modePopup selectItemWithTitle:MTRegionTitle];
    } else if ([defaults objectForKey:@"recordDisplayID"]) {
        [self.modePopup selectItemWithTag:[defaults integerForKey:@"recordDisplayID"]];
    }
    NSString *region = [defaults stringForKey:@"recordRegion"];
    if (region) self.region = NSRectFromString(region);
    self.regionDisplayID = (CGDirectDisplayID)[defaults integerForKey:@"recordRegionDisplayID"];
    if ([defaults integerForKey:@"recordFPS"] == 60) [self.fpsPopup selectItemWithTag:60];
    if ([defaults objectForKey:@"recordCursor"]) {
        self.cursorCheckbox.state = [defaults boolForKey:@"recordCursor"] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    self.autoRecordCheckbox.state = [defaults boolForKey:@"recordWithTyping"] ? NSControlStateValueOn : NSControlStateValueOff;
    NSString *folder = [defaults stringForKey:@"recordFolder"];
    if (folder.length) self.folderURL = [NSURL fileURLWithPath:folder isDirectory:YES];
}

- (void)saveSettings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:[self regionMode] ? @"region" : @"screen" forKey:@"recordMode"];
    if (![self regionMode]) [defaults setInteger:self.modePopup.selectedItem.tag forKey:@"recordDisplayID"];
    [defaults setObject:NSStringFromRect(self.region) forKey:@"recordRegion"];
    [defaults setInteger:self.regionDisplayID forKey:@"recordRegionDisplayID"];
    [defaults setInteger:self.fpsPopup.selectedItem.tag forKey:@"recordFPS"];
    [defaults setBool:self.cursorCheckbox.state == NSControlStateValueOn forKey:@"recordCursor"];
    [defaults setBool:self.autoRecordWithTyping forKey:@"recordWithTyping"];
    [defaults setObject:self.folderURL.path forKey:@"recordFolder"];
}

#pragma mark - 操作

- (void)selectRegion:(id)sender {
    if (self.recorder.recording || self.recorder.busy) return;
    BOOL mainVisible = self.mainWindow.isVisible;
    [self.mainWindow orderOut:nil];
    [MTRegionSelector selectRegionWithCompletion:^(NSRect rect, NSScreen *screen) {
        if (mainVisible) [self.mainWindow makeKeyAndOrderFront:nil];
        if (!screen || NSIsEmptyRect(rect)) {
            [self status:@"已取消选择区域"];
            return;
        }
        self.region = rect;
        self.regionDisplayID = MTDisplayID(screen);
        [self.modePopup selectItemWithTitle:MTRegionTitle];
        [self saveSettings];
        [self updateControls];
        [self status:[NSString stringWithFormat:@"录制区域：%.0f × %.0f", rect.size.width, rect.size.height]];
    }];
}

- (void)chooseFolder:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.canCreateDirectories = YES;
    panel.prompt = @"选择";
    panel.directoryURL = self.folderURL;
    void (^handler)(NSModalResponse) = ^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) return;
        self.folderURL = panel.URL;
        [self saveSettings];
        [self updateControls];
    };
    if (self.mainWindow) {
        [panel beginSheetModalForWindow:self.mainWindow completionHandler:handler];
    } else {
        handler([panel runModal]);
    }
}

- (void)revealInFinder:(id)sender {
    if (self.lastRecordingURL && [NSFileManager.defaultManager fileExistsAtPath:self.lastRecordingURL.path]) {
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[self.lastRecordingURL]];
        return;
    }
    [NSFileManager.defaultManager createDirectoryAtURL:self.folderURL withIntermediateDirectories:YES attributes:nil error:NULL];
    [NSWorkspace.sharedWorkspace openURL:self.folderURL];
}

- (void)toggleRecording:(id)sender {
    if (self.recorder.recording) {
        self.startedByTyping = NO;
        [self stopWithCompletion:nil];
    } else {
        [self startWithCompletion:nil];
    }
}

- (void)startWithCompletion:(void (^_Nullable)(BOOL ok))done {
    if (self.recorder.recording || self.recorder.busy) {
        if (done) done(self.recorder.recording);
        return;
    }
    NSScreen *screen;
    CGRect local = CGRectNull;
    if ([self regionMode]) {
        screen = MTScreenWithID(self.regionDisplayID);
        local = screen ? MTDisplayLocalRect(self.region, screen.frame) : CGRectNull;
        if (!screen || CGRectIsNull(local)) {
            [self status:@"请先在“录屏”页选择录制区域"];
            if (done) done(NO);
            return;
        }
    } else {
        screen = MTScreenWithID((CGDirectDisplayID)self.modePopup.selectedItem.tag) ?: NSScreen.screens.firstObject;
    }
    NSURL *url = [self.folderURL URLByAppendingPathComponent:MTRecordingFileName([NSDate date])];
    [self status:@"正在开始录屏…"];
    [self.recorder startOnDisplay:MTDisplayID(screen)
                             rect:local
                            scale:screen.backingScaleFactor
                              fps:self.fpsPopup.selectedItem.tag
                      showsCursor:self.cursorCheckbox.state == NSControlStateValueOn
                        outputURL:url
                       completion:^(NSError *error) {
        if (error) {
            [self status:[NSString stringWithFormat:@"录屏失败：%@。请在 系统设置 > 隐私与安全性 > 屏幕与系统录音 中允许 Mac Typer 后重新打开 App",
                          error.localizedDescription]];
            [self updateControls];
            if (done) done(NO);
            return;
        }
        if ([self regionMode]) self.borderWindow = [MTRegionSelector borderWindowForRect:self.region];
        self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
        [self tick:nil];
        [self status:@"正在录屏"];
        [self updateControls];
        if (done) done(YES);
    }];
    [self updateControls];
}

- (void)tick:(NSTimer *)timer {
    NSDate *started = self.recorder.startedAt;
    self.timeLabel.stringValue = started ? [@"● 录制中 " stringByAppendingString:MTDurationText(-started.timeIntervalSinceNow)] : @"";
}

- (void)stopWithCompletion:(void (^_Nullable)(void))done {
    if (!self.recorder.recording) {
        if (done) done();
        return;
    }
    [self status:@"正在保存录屏…"];
    [self.recorder stopWithCompletion:^(NSURL *url, NSError *error) {
        [self didStopWithURL:url error:error prefix:@"保存录屏失败"];
        if (done) done();
    }];
    [self updateControls];
}

- (void)didStopWithURL:(NSURL *)url error:(NSError *)error prefix:(NSString *)prefix {
    [self.timer invalidate];
    self.timer = nil;
    [self.borderWindow orderOut:nil];
    self.borderWindow = nil;
    self.startedByTyping = NO;
    if (url) {
        self.lastRecordingURL = url;
        [self status:[NSString stringWithFormat:@"录屏已保存：%@", url.lastPathComponent]];
    } else {
        [self status:[NSString stringWithFormat:@"%@：%@", prefix, error.localizedDescription ?: @"未知错误"]];
    }
    [self updateControls];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(toggleRecording:)) {
        item.title = self.recorder.recording ? @"停止录屏" : @"开始录屏";
        return !self.recorder.busy;
    }
    return YES;
}

#pragma mark - 随键入录屏

- (void)typingWillStart:(void (^)(void))ready {
    if (!self.autoRecordWithTyping || self.recorder.recording) {
        ready();
        return;
    }
    [self startWithCompletion:^(BOOL ok) {
        self.startedByTyping = ok;
        ready();
    }];
}

- (void)typingDidEnd {
    if (!self.startedByTyping) return;
    // 留一秒尾巴，让最后输入的字在录像里显示出来。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.startedByTyping) [self stopWithCompletion:nil];
    });
}

- (void)stopForTerminationWithCompletion:(void (^)(void))completion {
    self.startedByTyping = NO;
    [self stopWithCompletion:completion];
}

@end
