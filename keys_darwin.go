package main

/*
#cgo darwin LDFLAGS: -framework ApplicationServices
#include <ApplicationServices/ApplicationServices.h>
#include <stdlib.h>

static int postText(const char *s) {
	if (!CGPreflightPostEventAccess()) return 0;
	CFStringRef str = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
	if (!str) return 0;
	CFIndex len = CFStringGetLength(str);
	UniChar *chars = malloc(sizeof(UniChar) * len);
	if (!chars) {
		CFRelease(str);
		return 0;
	}
	CFStringGetCharacters(str, CFRangeMake(0, len), chars);
	CGEventRef down = CGEventCreateKeyboardEvent(NULL, 0, true);
	CGEventRef up = CGEventCreateKeyboardEvent(NULL, 0, false);
	if (!down || !up) {
		if (down) CFRelease(down);
		if (up) CFRelease(up);
		free(chars);
		CFRelease(str);
		return 0;
	}
	CGEventKeyboardSetUnicodeString(down, len, chars);
	CGEventKeyboardSetUnicodeString(up, len, chars);
	CGEventPost(kCGHIDEventTap, down);
	CGEventPost(kCGHIDEventTap, up);
	CFRelease(down);
	CFRelease(up);
	free(chars);
	CFRelease(str);
	return 1;
}

static int postBackspace(void) {
	if (!CGPreflightPostEventAccess()) return 0;
	CGEventRef down = CGEventCreateKeyboardEvent(NULL, 51, true);
	CGEventRef up = CGEventCreateKeyboardEvent(NULL, 51, false);
	if (!down || !up) {
		if (down) CFRelease(down);
		if (up) CFRelease(up);
		return 0;
	}
	CGEventPost(kCGHIDEventTap, down);
	CGEventPost(kCGHIDEventTap, up);
	CFRelease(down);
	CFRelease(up);
	return 1;
}
*/
import "C"

import (
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"unsafe"
)

var eventWriter io.Writer = os.Stdout

func keystroke(s string) error {
	if eventStream {
		_, err := fmt.Fprintln(eventWriter, encodeTextEvent(s))
		return err
	}
	cs := C.CString(s)
	defer C.free(unsafe.Pointer(cs))
	if C.postText(cs) == 0 {
		return fmt.Errorf("系统键入失败：无法创建键盘事件，请确认 Mac Typer 已获得辅助功能权限")
	}
	return nil
}

func sendBackspace(n int) error {
	if eventStream {
		_, err := fmt.Fprintln(eventWriter, encodeBackspaceEvent(n))
		return err
	}
	for i := 0; i < n; i++ {
		if C.postBackspace() == 0 {
			return fmt.Errorf("系统删除失败：无法创建键盘事件")
		}
	}
	return nil
}

func encodeTextEvent(s string) string {
	return "T" + base64.StdEncoding.EncodeToString([]byte(s))
}

func encodeBackspaceEvent(n int) string {
	return fmt.Sprintf("B%d", n)
}
