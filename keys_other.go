//go:build !darwin

package main

import "fmt"

func postNativeText(string) error {
	return fmt.Errorf("系统键入仅支持 macOS")
}

func postNativeBackspace() error {
	return fmt.Errorf("系统删除仅支持 macOS")
}
