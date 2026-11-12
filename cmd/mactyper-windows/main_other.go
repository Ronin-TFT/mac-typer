//go:build !windows

package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Fprintln(os.Stderr, "这是 Mac Typer 的 Windows 版，请在 Windows 上运行。macOS 请使用 Mac Typer.app。")
	os.Exit(1)
}
