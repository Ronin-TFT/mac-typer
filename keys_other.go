//go:build !darwin

package main

import "fmt"

// nativeSink 通过系统键盘事件发送按键。
type nativeSink struct{}

func (nativeSink) Text(s string) error { return postNativeText(s) }
func (nativeSink) Backspace() error    { return postNativeBackspace() }

func postNativeText(string) error {
	return fmt.Errorf("系统键入仅支持 macOS")
}

func postNativeBackspace() error {
	return fmt.Errorf("系统删除仅支持 macOS")
}
