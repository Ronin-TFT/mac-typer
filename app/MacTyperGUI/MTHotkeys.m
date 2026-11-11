#import "MTHotkeys.h"
#import <Carbon/Carbon.h>

@implementation MTHotkey

- (instancetype)initWithKeyCode:(NSUInteger)keyCode modifiers:(NSEventModifierFlags)modifiers displayName:(NSString *)displayName {
    if ((self = [super init])) {
        _keyCode = keyCode;
        _modifiers = modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                  NSEventModifierFlagControl | NSEventModifierFlagShift);
        _displayName = [displayName copy];
    }
    return self;
}

+ (instancetype)hotkeyWithEvent:(NSEvent *)event {
    NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (!(mods & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl))) return nil;
    NSMutableString *name = [NSMutableString string];
    if (mods & NSEventModifierFlagControl) [name appendString:@"⌃"];
    if (mods & NSEventModifierFlagOption) [name appendString:@"⌥"];
    if (mods & NSEventModifierFlagShift) [name appendString:@"⇧"];
    if (mods & NSEventModifierFlagCommand) [name appendString:@"⌘"];
    NSString *key = event.keyCode == 36 ? @"↩" : event.charactersIgnoringModifiers.uppercaseString;
    [name appendString:key ?: @""];
    return [[self alloc] initWithKeyCode:event.keyCode modifiers:mods displayName:name];
}

- (UInt32)carbonModifiers {
    UInt32 result = 0;
    if (self.modifiers & NSEventModifierFlagCommand) result |= cmdKey;
    if (self.modifiers & NSEventModifierFlagOption) result |= optionKey;
    if (self.modifiers & NSEventModifierFlagControl) result |= controlKey;
    if (self.modifiers & NSEventModifierFlagShift) result |= shiftKey;
    return result;
}

@end

@interface MTHotkeyCenter () {
    EventHandlerRef _handlerRef;
    EventHotKeyRef _refs[3];
}
- (void)fire:(UInt32)identifier;
@end

static OSStatus MTHotkeyEventHandler(EventHandlerCallRef next, EventRef event, void *userData) {
    EventHotKeyID hotkeyID;
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL,
                          sizeof(hotkeyID), NULL, &hotkeyID) != noErr) return eventNotHandledErr;
    [(__bridge MTHotkeyCenter *)userData fire:hotkeyID.id];
    return noErr;
}

@implementation MTHotkeyCenter

- (BOOL)install {
    if (_handlerRef) return YES;
    EventTypeSpec type = {kEventClassKeyboard, kEventHotKeyPressed};
    return InstallEventHandler(GetApplicationEventTarget(), MTHotkeyEventHandler, 1, &type,
                               (__bridge void *)self, &_handlerRef) == noErr;
}

- (void)fire:(UInt32)identifier {
    if (identifier >= MTHotkeyActionStart && identifier <= MTHotkeyActionStop && self.handler) {
        self.handler((MTHotkeyAction)identifier);
    }
}

- (BOOL)registerHotkeys:(NSArray<MTHotkey *> *)hotkeys {
    [self unregisterAll];
    if (hotkeys.count != 3) return NO;
    for (UInt32 i = 0; i < 3; i++) {
        EventHotKeyID hotkeyID = {'MTYP', i + 1};
        MTHotkey *hotkey = hotkeys[i];
        if (RegisterEventHotKey((UInt32)hotkey.keyCode, [hotkey carbonModifiers], hotkeyID,
                                GetApplicationEventTarget(), 0, &_refs[i]) != noErr) {
            _refs[i] = NULL;
            [self unregisterAll];
            return NO;
        }
    }
    return YES;
}

- (void)unregisterAll {
    for (int i = 0; i < 3; i++) {
        if (_refs[i]) UnregisterEventHotKey(_refs[i]);
        _refs[i] = NULL;
    }
}

- (void)uninstall {
    [self unregisterAll];
    if (_handlerRef) RemoveEventHandler(_handlerRef);
    _handlerRef = NULL;
}

- (void)dealloc {
    [self uninstall];
}

@end
