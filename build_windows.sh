#!/bin/sh
# 交叉编译 Windows 版（x64 与 ARM64），不需要 C 编译器，可在 macOS、Linux 或 Windows（Git Bash）上运行。
# 输出：dist/MacTyper-windows-amd64.exe、dist/MacTyper-windows-arm64.exe
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
VERSION="$(sed -n 's/^const version = "\(.*\)"/\1/p' cmd/mactyper-windows/logic.go)"
mkdir -p build dist

# 图标、版本信息与高分屏清单（需要联网下载 go-winres；失败时跳过，不影响功能）。
go run ./app/make_icon.go
if (cd cmd/mactyper-windows && go run github.com/tc-hib/go-winres@v0.3.3 simply \
      --icon ../../build/icon.png --manifest gui \
      --product-name "Mac Typer" --file-description "Mac Typer for Windows" \
      --product-version "$VERSION" --file-version "$VERSION" --arch amd64,arm64); then
  echo "已生成图标资源"
else
  echo "警告：未能生成图标资源，exe 将使用默认图标" >&2
fi

for arch in amd64 arm64; do
  GOOS=windows GOARCH=$arch CGO_ENABLED=0 go build -trimpath -ldflags "-H windowsgui -s -w" \
    -o "dist/MacTyper-windows-$arch.exe" ./cmd/mactyper-windows
  echo "dist/MacTyper-windows-$arch.exe"
done
