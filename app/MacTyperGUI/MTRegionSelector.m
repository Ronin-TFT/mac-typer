#import "MTRegionSelector.h"
#import <math.h>

static const CGFloat MTMinimumRegionSize = 20;

@interface MTOverlayWindow : NSWindow
@end

@implementation MTOverlayWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@interface MTRegionSelector ()
@property (nonatomic, strong) NSMutableArray<NSWindow *> *windows;
@property (nonatomic, copy) void (^completion)(NSRect, NSScreen *);
- (void)finishWithRect:(NSRect)localRect inWindow:(NSWindow *)window;
- (void)cancel;
@end

@interface MTRegionView : NSView
@property (nonatomic, weak) MTRegionSelector *selector;
@property (nonatomic) NSPoint anchor;
@property (nonatomic) NSRect selection;
@end

@implementation MTRegionView

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:NSCursor.crosshairCursor];
}

- (NSPoint)clampedPoint:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    p.x = MIN(MAX(p.x, NSMinX(self.bounds)), NSMaxX(self.bounds));
    p.y = MIN(MAX(p.y, NSMinY(self.bounds)), NSMaxY(self.bounds));
    return p;
}

- (void)mouseDown:(NSEvent *)event {
    self.anchor = [self clampedPoint:event];
    self.selection = NSZeroRect;
    [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint p = [self clampedPoint:event];
    self.selection = NSMakeRect(MIN(p.x, self.anchor.x), MIN(p.y, self.anchor.y),
                                fabs(p.x - self.anchor.x), fabs(p.y - self.anchor.y));
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event {
    if (self.selection.size.width >= MTMinimumRegionSize && self.selection.size.height >= MTMinimumRegionSize) {
        [self.selector finishWithRect:NSIntegralRect(self.selection) inWindow:self.window];
    } else {
        self.selection = NSZeroRect;
        [self setNeedsDisplay:YES];
    }
}

- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 53) {
        [self.selector cancel];
    } else if (event.keyCode == 36 || event.keyCode == 76) {
        [self.selector finishWithRect:self.bounds inWindow:self.window];
    } else {
        [super keyDown:event];
    }
}

- (void)drawString:(NSString *)text centeredAt:(NSPoint)center {
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:14 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: NSColor.whiteColor,
    };
    NSSize size = [text sizeWithAttributes:attributes];
    NSRect box = NSMakeRect(center.x - size.width / 2 - 10, center.y - size.height / 2 - 5, size.width + 20, size.height + 10);
    [[NSColor colorWithWhite:0 alpha:0.7] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:box xRadius:6 yRadius:6] fill];
    [text drawAtPoint:NSMakePoint(NSMinX(box) + 10, NSMinY(box) + 5) withAttributes:attributes];
}

- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor colorWithWhite:0 alpha:0.35] setFill];
    NSRectFill(self.bounds);
    if (!NSIsEmptyRect(self.selection)) {
        [NSColor.clearColor setFill];
        NSRectFillUsingOperation(self.selection, NSCompositingOperationCopy);
        NSBezierPath *border = [NSBezierPath bezierPathWithRect:NSInsetRect(self.selection, -1, -1)];
        border.lineWidth = 2;
        [NSColor.systemRedColor setStroke];
        [border stroke];
        NSString *size = [NSString stringWithFormat:@"%.0f × %.0f", self.selection.size.width, self.selection.size.height];
        CGFloat labelY = NSMaxY(self.selection) + 18;
        if (labelY > NSMaxY(self.bounds) - 20) labelY = NSMaxY(self.selection) - 18;
        [self drawString:size centeredAt:NSMakePoint(NSMidX(self.selection), labelY)];
    }
    [self drawString:@"拖拽选择录制区域 · 回车录制整个屏幕 · Esc 取消"
          centeredAt:NSMakePoint(NSMidX(self.bounds), NSMaxY(self.bounds) - 60)];
}

@end

@interface MTBorderView : NSView
@end

@implementation MTBorderView
- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *path = [NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds, 1.5, 1.5)];
    path.lineWidth = 3;
    CGFloat dash[] = {8, 5};
    [path setLineDash:dash count:2 phase:0];
    [NSColor.systemRedColor setStroke];
    [path stroke];
}
@end

static MTRegionSelector *MTActiveSelector;

@implementation MTRegionSelector

+ (void)selectRegionWithCompletion:(void (^)(NSRect, NSScreen *))completion {
    if (MTActiveSelector) return;
    MTRegionSelector *selector = [MTRegionSelector new];
    selector.completion = completion;
    selector.windows = [NSMutableArray array];
    MTActiveSelector = selector;

    NSPoint mouse = NSEvent.mouseLocation;
    NSWindow *keyWindow = nil;
    for (NSScreen *screen in NSScreen.screens) {
        MTOverlayWindow *window = [[MTOverlayWindow alloc] initWithContentRect:screen.frame
                                                                     styleMask:NSWindowStyleMaskBorderless
                                                                       backing:NSBackingStoreBuffered
                                                                         defer:NO];
        [window setFrame:screen.frame display:NO];
        window.releasedWhenClosed = NO;
        window.opaque = NO;
        window.backgroundColor = NSColor.clearColor;
        window.hasShadow = NO;
        window.level = NSScreenSaverWindowLevel;
        window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
        MTRegionView *view = [[MTRegionView alloc] initWithFrame:NSMakeRect(0, 0, screen.frame.size.width, screen.frame.size.height)];
        view.selector = selector;
        window.contentView = view;
        [window orderFrontRegardless];
        [selector.windows addObject:window];
        if (NSPointInRect(mouse, screen.frame)) keyWindow = window;
    }
    [NSApp activateIgnoringOtherApps:YES];
    keyWindow = keyWindow ?: selector.windows.firstObject;
    [keyWindow makeKeyAndOrderFront:nil];
    [keyWindow makeFirstResponder:keyWindow.contentView];
}

- (void)closeAll {
    for (NSWindow *window in self.windows) [window orderOut:nil];
    [self.windows removeAllObjects];
    MTActiveSelector = nil;
}

- (void)finishWithRect:(NSRect)localRect inWindow:(NSWindow *)window {
    NSRect global = NSOffsetRect(localRect, window.frame.origin.x, window.frame.origin.y);
    NSScreen *screen = window.screen;
    void (^completion)(NSRect, NSScreen *) = self.completion;
    [self closeAll];
    if (completion) completion(global, screen);
}

- (void)cancel {
    void (^completion)(NSRect, NSScreen *) = self.completion;
    [self closeAll];
    if (completion) completion(NSZeroRect, nil);
}

+ (NSWindow *)borderWindowForRect:(NSRect)globalRect {
    NSRect frame = NSInsetRect(globalRect, -4, -4);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered defer:NO];
    [window setFrame:frame display:NO];
    window.releasedWhenClosed = NO;
    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
    window.hasShadow = NO;
    window.ignoresMouseEvents = YES;
    window.level = NSStatusWindowLevel;
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary;
    window.contentView = [[MTBorderView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    [window orderFrontRegardless];
    return window;
}

@end
