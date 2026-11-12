//go:build windows && (amd64 || arm64)

package main

import (
	"fmt"
	"runtime"
	"sync"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"
)

var (
	user32   = syscall.NewLazyDLL("user32.dll")
	kernel32 = syscall.NewLazyDLL("kernel32.dll")
	shell32  = syscall.NewLazyDLL("shell32.dll")

	procSendInput                     = user32.NewProc("SendInput")
	procGetAsyncKeyState              = user32.NewProc("GetAsyncKeyState")
	procRegisterHotKey                = user32.NewProc("RegisterHotKey")
	procUnregisterHotKey              = user32.NewProc("UnregisterHotKey")
	procGetMessageW                   = user32.NewProc("GetMessageW")
	procPeekMessageW                  = user32.NewProc("PeekMessageW")
	procPostThreadMessageW            = user32.NewProc("PostThreadMessageW")
	procMessageBoxW                   = user32.NewProc("MessageBoxW")
	procSetProcessDpiAwarenessContext = user32.NewProc("SetProcessDpiAwarenessContext")
	procGetCurrentThreadId            = kernel32.NewProc("GetCurrentThreadId")
	procShellExecuteW                 = shell32.NewProc("ShellExecuteW")
)

const (
	inputKeyboard   = 1
	keyEventKeyUp   = 0x0002
	keyEventUnicode = 0x0004

	vkBack    = 0x08
	vkTab     = 0x09
	vkReturn  = 0x0D
	vkShift   = 0x10
	vkControl = 0x11
	vkMenu    = 0x12
	vkLWin    = 0x5B
	vkRWin    = 0x5C

	wmQuit   = 0x0012
	wmHotkey = 0x0312
	wmApp    = 0x8000

	modNoRepeat = 0x4000
	pmNoRemove  = 0x0000
)

// keyboardInput 与 input 对应 Win32 的 KEYBDINPUT / INPUT（64 位布局，共 40 字节）。
type keyboardInput struct {
	vk        uint16
	scan      uint16
	flags     uint32
	time      uint32
	extraInfo uintptr
}

type input struct {
	kind uint32
	_    uint32
	ki   keyboardInput
	_    [8]byte
}

type point struct{ x, y int32 }

type msg struct {
	hwnd    uintptr
	message uint32
	wParam  uintptr
	lParam  uintptr
	time    uint32
	pt      point
	private uint32
}

func sendInputs(inputs []input) error {
	if len(inputs) == 0 {
		return nil
	}
	n, _, err := procSendInput.Call(uintptr(len(inputs)), uintptr(unsafe.Pointer(&inputs[0])), unsafe.Sizeof(inputs[0]))
	if int(n) != len(inputs) {
		return fmt.Errorf("发送按键失败（%v）。如果目标程序以管理员身份运行，请也以管理员身份运行 Mac Typer", err)
	}
	return nil
}

func keyPress(vk uint16) []input {
	return []input{
		{kind: inputKeyboard, ki: keyboardInput{vk: vk}},
		{kind: inputKeyboard, ki: keyboardInput{vk: vk, flags: keyEventKeyUp}},
	}
}

// sendInputSink 用 SendInput 发送按键：普通字符用 Unicode 方式，换行、Tab、退格用真实按键。
type sendInputSink struct{}

func (sendInputSink) Text(s string) error {
	switch s {
	case "\n", "\r":
		return sendInputs(keyPress(vkReturn))
	case "\t":
		return sendInputs(keyPress(vkTab))
	}
	var inputs []input
	for _, unit := range utf16.Encode([]rune(s)) {
		inputs = append(inputs,
			input{kind: inputKeyboard, ki: keyboardInput{scan: unit, flags: keyEventUnicode}},
			input{kind: inputKeyboard, ki: keyboardInput{scan: unit, flags: keyEventUnicode | keyEventKeyUp}},
		)
	}
	return sendInputs(inputs)
}

func (sendInputSink) Backspace() error { return sendInputs(keyPress(vkBack)) }

// modifiersHeld 判断 Ctrl、Alt、Shift、Win 是否仍被按住。
func modifiersHeld() bool {
	for _, vk := range []uintptr{vkControl, vkMenu, vkShift, vkLWin, vkRWin} {
		state, _, _ := procGetAsyncKeyState.Call(vk)
		if state&0x8000 != 0 {
			return true
		}
	}
	return false
}

// waitModifiersReleased 最多等待 timeout，直到用户松开修饰键。
func waitModifiersReleased(timeout time.Duration) {
	deadline := time.Now().Add(timeout)
	for modifiersHeld() && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
}

// hotkeyManager 在专用线程上注册全局快捷键并接收 WM_HOTKEY。
type hotkeyManager struct {
	threadID uint32
	mu       sync.Mutex
	requests chan []hotkey
	results  chan error
	onPress  func(id int)
}

func startHotkeyManager(onPress func(id int)) *hotkeyManager {
	m := &hotkeyManager{requests: make(chan []hotkey, 1), results: make(chan error, 1), onPress: onPress}
	ready := make(chan struct{})
	go func() {
		runtime.LockOSThread()
		id, _, _ := procGetCurrentThreadId.Call()
		m.threadID = uint32(id)
		var message msg
		// 先创建线程消息队列，之后 PostThreadMessage 才能送达。
		procPeekMessageW.Call(uintptr(unsafe.Pointer(&message)), 0, 0, 0, pmNoRemove)
		close(ready)
		for {
			r, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&message)), 0, 0, 0)
			if int32(r) <= 0 {
				return
			}
			switch message.message {
			case wmHotkey:
				if m.onPress != nil {
					m.onPress(int(message.wParam))
				}
			case wmApp + 1:
				m.results <- m.register(<-m.requests)
			}
		}
	}()
	<-ready
	return m
}

// register 必须在快捷键线程上调用。传入空列表表示全部注销（录制新快捷键时使用）。
func (m *hotkeyManager) register(keys []hotkey) error {
	for id := 1; id <= 3; id++ {
		procUnregisterHotKey.Call(0, uintptr(id))
	}
	for i, k := range keys {
		r, _, err := procRegisterHotKey.Call(0, uintptr(i+1), uintptr(k.Mods|modNoRepeat), uintptr(k.VK))
		if r == 0 {
			for id := 1; id <= 3; id++ {
				procUnregisterHotKey.Call(0, uintptr(id))
			}
			return fmt.Errorf("快捷键 %s 注册失败，可能已被其他软件占用（%v）", k.Name, err)
		}
	}
	return nil
}

// Register 在快捷键线程上替换全部快捷键。
func (m *hotkeyManager) Register(keys []hotkey) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.requests <- keys
	r, _, err := procPostThreadMessageW.Call(uintptr(m.threadID), wmApp+1, 0, 0)
	if r == 0 {
		<-m.requests
		return fmt.Errorf("快捷键服务无响应（%v）", err)
	}
	return <-m.results
}

func (m *hotkeyManager) Close() {
	procPostThreadMessageW.Call(uintptr(m.threadID), wmQuit, 0, 0)
}

func utf16Ptr(s string) uintptr {
	p, _ := syscall.UTF16PtrFromString(s)
	return uintptr(unsafe.Pointer(p))
}

func messageBox(title, text string) {
	procMessageBoxW.Call(0, utf16Ptr(text), utf16Ptr(title), 0x40) // MB_ICONINFORMATION
}

func openURL(url string) {
	procShellExecuteW.Call(0, utf16Ptr("open"), utf16Ptr(url), 0, 0, 1)
}

// enableDPIAwareness 让界面在高分屏上清晰显示（Windows 10 1703 及以上）。
func enableDPIAwareness() {
	if procSetProcessDpiAwarenessContext.Find() == nil {
		const perMonitorAwareV2 = ^uintptr(3) // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
		procSetProcessDpiAwarenessContext.Call(perMonitorAwareV2)
	}
}
