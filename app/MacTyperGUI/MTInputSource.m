#import "MTInputSource.h"
#import <Carbon/Carbon.h>

static BOOL MTSourceIsASCIICapable(TISInputSourceRef source) {
    CFBooleanRef value = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable);
    return value && CFBooleanGetValue(value);
}

@implementation MTInputSource

+ (BOOL)currentIsASCIICapable {
    TISInputSourceRef current = TISCopyCurrentKeyboardInputSource();
    if (!current) return YES;
    BOOL result = MTSourceIsASCIICapable(current);
    CFRelease(current);
    return result;
}

+ (id)switchToASCIICapable {
    TISInputSourceRef current = TISCopyCurrentKeyboardInputSource();
    if (!current) return nil;
    if (MTSourceIsASCIICapable(current)) {
        CFRelease(current);
        return nil;
    }
    TISInputSourceRef target = TISCopyCurrentASCIICapableKeyboardInputSource();
    OSStatus status = target ? TISSelectInputSource(target) : paramErr;
    if (target) CFRelease(target);
    if (status != noErr) {
        CFRelease(current);
        return nil;
    }
    return CFBridgingRelease(current);
}

+ (void)restore:(id)saved {
    if (saved) TISSelectInputSource((__bridge TISInputSourceRef)saved);
}

@end
