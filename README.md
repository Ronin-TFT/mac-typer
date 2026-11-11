# Mac Typer

macOS 图形化模拟键入工具。打字引擎使用 Go（编译为静态库链接进 App），界面使用原生 AppKit。

## 功能

- 基础输入间隔和随机抖动，支持 `ms` / `秒` 切换
- **自然节奏**：标点和换行后停顿更久、词内连击更快、偶尔犹豫
- **错词库**：按“错词概率”打错整词，再删除整个错词或只删错误部分后重输
- **手误**：按“手误概率”误按相邻键（有时多打一个字母才发现），随后删除并改正
- 输入框可直接拖入文本文件，或用“导入文本…”（⌘O）；支持 UTF-8、UTF-16、GB18030
- 进度条与“已输入 x/y · 约剩 m:ss”提示，倒计时显示在状态栏
- 全局开始、暂停/继续、结束快捷键，可在设置中录制；快捷键启动会等待松开修饰键
- **菜单栏模式**：关闭窗口后保留在菜单栏，快捷键和菜单继续可用（可在设置中关闭）
- 记住全部参数、窗口位置和快捷键

## 1.1.0 更新

- 合并为单进程：打字引擎直接在 App 内运行，暂停和结束立即生效，最后一个字发完才显示“完成”。
- 新增自然节奏、手误、进度与剩余时间、文本文件导入、菜单栏模式。
- 通用版安装包，同时支持 Apple Silicon 和 Intel。
- 界面改用自动布局，窗口可调整大小；关闭输入框的智能引号和自动替换，保证输入内容与原文一致。
- 发送按键时清空修饰键，换行和 Tab 使用真实按键；错词匹配遵守词边界并支持错词概率。
- 签名改为自签名证书，防止其他程序冒用辅助功能权限。
  **从 1.0.x 升级需要在“辅助功能”中移除旧的 Mac Typer 记录并重新授权一次**，之后用同一证书签名的版本无需再授权。
- 界面代码按模块拆分；新增 Linux 与 macOS 自动测试。

真实目标输入及后台快捷键仍需在目标机器上验收；自动化测试不代表所有输入框兼容。

## 安装

从 [最新 Release](https://github.com/Ronin-TFT/mac-typer/releases/latest) 下载 `MacTyper.dmg`，打开后把 **Mac Typer** 拖入“应用程序”。
支持 Apple Silicon 和 Intel Mac（通用版），要求 macOS 13+。
更新时完整替换原应用，避免旧文件残留导致签名失效。首次运行在：

`系统设置 -> 隐私与安全性 -> 辅助功能`

只为 **Mac Typer** 打开权限，不需要为终端重复授权。
若旧版权限开关已经开启但应用仍提示未放行，移除旧记录，重新添加“应用程序”中的当前版本并重启。
当前使用自签名证书，没有 Developer ID 和公证；macOS 会拦截首次打开，需要在“系统设置 → 隐私与安全性”中点“仍要打开”。

默认快捷键：

- 开始：`⌥⌘B`
- 暂停/继续：`⌥⌘N`
- 结束：`⌥⌘M`

## 错词库

程序读取的格式为 `错词=>正确词`：

```txt
teh=>the
adress=>address
```

`#` 开头的行是注释。图形界面的“错词库工具”使用 `正确词=>错词`，保存时会自动转换。
规则只在完整单词上触发（`the` 不会命中 `other`），多条规则时优先最长的一条；
中文、日文没有空格分词，不受这个限制。

## 命令行

同一份 Go 代码也可以编译成命令行工具：

```sh
go build -o mac-typer .
./mac-typer -text article.txt -delay 80ms -jitter 60ms -natural -slip-rate 0.02 -typos typos.example.txt
```

`kill -USR1 <pid>` 可暂停/继续。运行 `./mac-typer -h` 查看全部参数。

## 构建与测试

需要 macOS 13+、Go 和 Xcode Command Line Tools。

```sh
go test -race ./...
go vet ./...
go build -buildmode=c-archive -o build/libmactyper.a .
clang -fobjc-arc -I build -I . -I app/MacTyperGUI tests/gui_test.m app/MacTyperGUI/MT*.m build/libmactyper.a \
  -framework Cocoa -framework ApplicationServices -framework Carbon -framework CoreFoundation -o build/gui-test
build/gui-test
SIGN_IDENTITY="Mac Typer Signing" ./build_dmg.sh
```

输出文件：`dist/MacTyper.dmg`。Go 引擎和 C 接口测试（`tests/bridge_test.c`）在 Linux 上也能运行。

### 代码结构

| 文件 | 作用 |
|---|---|
| `engine.go` | 打字引擎：节奏、错词、手误、暂停/结束、进度 |
| `bridge.go`、`engine_bridge.h` | 导出给界面的 C 接口 |
| `keys_darwin.go` | 发送系统键盘事件 |
| `main.go` | 命令行入口、输入与错词库读取 |
| `app/MacTyperGUI/MTAppDelegate.m` | 窗口、设置、执行流程、菜单栏 |
| `app/MacTyperGUI/MTEngine.m` | 引擎的 Objective-C 封装 |
| `app/MacTyperGUI/MTHotkeys.m` | 全局快捷键 |
| `app/MacTyperGUI/MTDropTextView.m`、`MTUtil.m` | 文本拖入导入、数值校验、进度文字 |

### 签名证书（不做公证）

发布版使用自签名“代码签名”证书。辅助功能权限绑定到这张证书，
其他程序无法冒用；用同一张证书签名的新版本无需重新授权。首次创建：

1. 打开“钥匙串访问” → 菜单“钥匙串访问 → 证书助理 → 创建证书…”。
2. 名称填 `Mac Typer Signing`，身份类型选“自签名根证书”，证书类型选“代码签名”，点“创建”。
3. 若签名时提示证书不受信任：在钥匙串中双击该证书 → “信任” → “代码签名”选“始终信任”。
4. 把证书连同私钥导出为 `.p12` 妥善备份。证书丢失后换新证书签名，所有用户都要重新授权。

不设置 `SIGN_IDENTITY` 时脚本会退回临时签名，每次更新都需要重新授权。
构建结束时会打印签名要求，应包含 `certificate leaf = H"..."`。

由于没有 Apple 公证，其他人从网上下载后首次打开会被拦截，需要在
“系统设置 → 隐私与安全性”中点“仍要打开”，每个新版本都要确认一次。
