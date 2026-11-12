package main

/*
#cgo darwin LDFLAGS: -framework ApplicationServices
#include <ApplicationServices/ApplicationServices.h>
#include <stdlib.h>

// 使用私有事件源并清空修饰键标志，避免用户仍按着 ⌘/⌥ 时
// 把普通字符变成快捷键（例如 ⌘A 全选后被覆盖）。
static CGEventSourceRef typerSource(void) {
	static CGEventSourceRef source = NULL;
	if (!source) source = CGEventSourceCreate(kCGEventSourceStatePrivate);
	return source;
}

static int postKey(CGKeyCode code, const UniChar *chars, CFIndex len) {
	if (!CGPreflightPostEventAccess()) return 0;
	CGEventRef down = CGEventCreateKeyboardEvent(typerSource(), code, true);
	CGEventRef up = CGEventCreateKeyboardEvent(typerSource(), code, false);
	if (!down || !up) {
		if (down) CFRelease(down);
		if (up) CFRelease(up);
		return 0;
	}
	CGEventSetFlags(down, 0);
	CGEventSetFlags(up, 0);
	if (chars && len > 0) {
		CGEventKeyboardSetUnicodeString(down, len, chars);
		CGEventKeyboardSetUnicodeString(up, len, chars);
	}
	CGEventPost(kCGHIDEventTap, down);
	CGEventPost(kCGHIDEventTap, up);
	CFRelease(down);
	CFRelease(up);
	return 1;
}

static int postText(const char *s) {
	CFStringRef str = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
	if (!str) return 0;
	CFIndex len = CFStringGetLength(str);
	if (len == 1) {
		UniChar c = CFStringGetCharacterAtIndex(str, 0);
		if (c == '\n' || c == '\r') {
			CFRelease(str);
			return postKey(36, NULL, 0);
		}
		if (c == '\t') {
			CFRelease(str);
			return postKey(48, NULL, 0);
		}
	}
	UniChar *chars = malloc(sizeof(UniChar) * (len > 0 ? len : 1));
	if (!chars) {
		CFRelease(str);
		return 0;
	}
	CFStringGetCharacters(str, CFRangeMake(0, len), chars);
	int ok = postKey(0, chars, len);
	free(chars);
	CFRelease(str);
	return ok;
}

static int postBackspace(void) {
	return postKey(51, NULL, 0);
}
*/
import "C"

import (
	"fmt"
	"unsafe"
)

// nativeSink 通过系统键盘事件发送按键。
type nativeSink struct{}

func (nativeSink) Text(s string) error { return postNativeText(s) }
func (nativeSink) Backspace() error    { return postNativeBackspace() }

func postNativeText(s string) error {
	cs := C.CString(s)
	defer C.free(unsafe.Pointer(cs))
	if C.postText(cs) == 0 {
		return fmt.Errorf("系统键入失败：无法创建键盘事件，请确认 Mac Typer 已获得辅助功能权限")
	}
	return nil
}

func postNativeBackspace() error {
	if C.postBackspace() == 0 {
		return fmt.Errorf("系统删除失败：无法创建键盘事件")
	}
	return nil
}
