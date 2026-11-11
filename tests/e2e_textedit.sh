#!/bin/zsh
# 端到端测试：在“文本编辑”里真实键入，并检查最终文字与原文一致。
# 需要：终端（或运行此脚本的程序）已获得“辅助功能”权限；首次运行会请求控制“文本编辑”的权限。
# 运行期间不要动键盘鼠标。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build
go build -o build/mac-typer .

EXPECTED=$'Hello world, this is the address test.\nThe quick brown fox jumps over the lazy dog!\n中文输入测试：你好，世界。\tTab end'
printf '%s' "$EXPECTED" > build/e2e-input.txt

run_case() {
  local name="$1"; shift
  osascript <<'APPLESCRIPT' >/dev/null
tell application "TextEdit"
  activate
  make new document
  set text of front document to ""
end tell
delay 1
APPLESCRIPT
  build/mac-typer -text build/e2e-input.txt -countdown 0 "$@"
  sleep 0.5
  local actual
  actual="$(osascript -e 'tell application "TextEdit" to get text of front document')"
  osascript -e 'tell application "TextEdit" to close front document saving no' >/dev/null
  if [[ "$actual" == "$EXPECTED" ]]; then
    echo "✅ $name"
  else
    echo "❌ $name"
    diff <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$actual") || true
    FAILED=1
  fi
}

FAILED=0
run_case "基础输入" -delay 15ms -jitter 10ms
run_case "错词库" -delay 15ms -jitter 10ms -typos typos.example.txt
run_case "自然节奏 + 手误 + 错词" -delay 15ms -jitter 10ms -natural -slip-rate 0.1 -typos typos.example.txt
exit $FAILED
