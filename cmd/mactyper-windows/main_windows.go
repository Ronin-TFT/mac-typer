//go:build windows && (amd64 || arm64)

package main

import (
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	webview2 "github.com/jchv/go-webview2"

	"mac-typer/internal/engine"
	"mac-typer/typos"
)

//go:embed ui.html
var uiHTML string

const webView2DownloadURL = "https://go.microsoft.com/fwlink/p/?LinkId=2124703"

type app struct {
	w       webview2.WebView
	hotkeys *hotkeyManager

	mu         sync.Mutex
	job        *engine.Job
	userPaused bool // 用户在倒计时期间按了暂停，准备好后保持暂停
}

func main() {
	enableDPIAwareness()
	dataDir := settingsDir()
	w := webview2.NewWithOptions(webview2.WebViewOptions{
		AutoFocus: true,
		DataPath:  filepath.Join(dataDir, "WebView2"),
		WindowOptions: webview2.WindowOptions{
			Title:  "Mac Typer",
			Width:  900,
			Height: 720,
			IconId: 1,
			Center: true,
		},
	})
	if w == nil {
		messageBox("Mac Typer", "需要 Microsoft Edge WebView2 运行时。点击确定后将打开下载页面，安装后重新打开 Mac Typer。")
		openURL(webView2DownloadURL)
		os.Exit(1)
	}
	defer w.Destroy()
	w.SetSize(760, 600, webview2.HintMin)

	a := &app{w: w}
	a.hotkeys = startHotkeyManager(func(id int) {
		w.Dispatch(func() { w.Eval(fmt.Sprintf("window.onHotkey && window.onHotkey(%d)", id)) })
	})
	defer a.hotkeys.Close()
	a.bind()
	w.SetHtml(uiHTML)
	w.Run()

	// 关闭窗口时结束正在进行的任务。
	a.mu.Lock()
	if a.job != nil {
		a.job.Stop()
	}
	a.mu.Unlock()
}

func settingsDir() string {
	base, err := os.UserConfigDir()
	if err != nil {
		base = os.TempDir()
	}
	dir := filepath.Join(base, "MacTyper")
	_ = os.MkdirAll(dir, 0o700)
	return dir
}

func settingsPath() string { return filepath.Join(settingsDir(), "settings.json") }

// emit 在界面线程上调用 window.onEngine(event)。
func (a *app) emit(event map[string]interface{}) {
	data, _ := json.Marshal(event)
	a.w.Dispatch(func() { a.w.Eval("window.onEngine && window.onEngine(" + string(data) + ")") })
}

func (a *app) bind() {
	must := func(err error) {
		if err != nil {
			panic(err)
		}
	}
	must(a.w.Bind("appInfo", func() map[string]interface{} {
		rules, _ := engine.ParseTypos(strings.NewReader(typos.Common))
		return map[string]interface{}{"version": version, "builtinCount": len(rules), "defaultHotkeys": defaultHotkeys}
	}))
	must(a.w.Bind("loadSettings", func() (map[string]interface{}, error) {
		data, err := os.ReadFile(settingsPath())
		if errors.Is(err, os.ErrNotExist) {
			return map[string]interface{}{}, nil
		}
		if err != nil {
			return nil, err
		}
		var out map[string]interface{}
		if err := json.Unmarshal(data, &out); err != nil {
			return map[string]interface{}{}, nil
		}
		return out, nil
	}))
	must(a.w.Bind("saveSettings", func(settings map[string]interface{}) error {
		data, err := json.MarshalIndent(settings, "", "  ")
		if err != nil {
			return err
		}
		tmp := settingsPath() + ".tmp"
		if err := os.WriteFile(tmp, data, 0o600); err != nil {
			return err
		}
		return os.Rename(tmp, settingsPath())
	}))
	must(a.w.Bind("validateTypos", func(text string) (int, error) {
		rules, err := (startRequest{TypoMode: "custom", TypoText: text}).typoRules()
		return len(rules), err
	}))
	must(a.w.Bind("registerHotkeys", func(keys []hotkey) error {
		if len(keys) > 0 {
			if err := validateHotkeys(keys); err != nil {
				return err
			}
		}
		return a.hotkeys.Register(keys)
	}))
	must(a.w.Bind("startTyping", a.start))
	must(a.w.Bind("setPaused", func(paused bool) error {
		a.mu.Lock()
		defer a.mu.Unlock()
		if a.job == nil {
			return fmt.Errorf("没有正在执行的任务")
		}
		a.userPaused = paused
		a.job.SetPaused(paused)
		return nil
	}))
	must(a.w.Bind("stopTyping", func() bool {
		a.mu.Lock()
		defer a.mu.Unlock()
		if a.job == nil {
			return false
		}
		a.job.Stop()
		return true
	}))
	// 绑定函数在界面线程上同步执行，网络请求放到后台，结果通过 update 事件返回。
	must(a.w.Bind("checkUpdate", func() {
		go func() {
			latest, url, err := fetchLatestRelease()
			event := map[string]interface{}{"type": "update"}
			if err != nil {
				event["error"] = err.Error()
			} else {
				event["latest"], event["url"], event["newer"] = latest, url, compareVersions(latest, version) > 0
			}
			a.emit(event)
		}()
	}))
	must(a.w.Bind("openReleasePage", func(url string) error {
		if !strings.HasPrefix(url, releasePagePrefix) {
			return fmt.Errorf("只能打开 Mac Typer 的发布页面")
		}
		openURL(url)
		return nil
	}))
}

func fetchLatestRelease() (string, string, error) {
	client := &http.Client{Timeout: 15 * time.Second}
	req, err := http.NewRequest(http.MethodGet, releaseAPI, nil)
	if err != nil {
		return "", "", err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "MacTyper")
	resp, err := client.Do(req)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("GitHub 返回 %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", "", err
	}
	return parseRelease(data)
}

// start 校验参数后在后台开始任务；倒计时结束后先等用户松开修饰键再输入。
func (a *app) start(req startRequest) error {
	cfg, err := req.config()
	if err != nil {
		return err
	}
	input, err := engine.PrepareInput(req.Text)
	if err != nil {
		return err
	}
	rules, err := req.typoRules()
	if err != nil {
		return err
	}

	a.mu.Lock()
	defer a.mu.Unlock()
	if a.job != nil {
		return fmt.Errorf("已有任务在执行")
	}
	job := engine.NewJob(cfg, rules, sendInputSink{}, time.Now().UnixNano())
	job.OnCountdown = func(n int) { a.emit(map[string]interface{}{"type": "countdown", "seconds": n}) }
	job.OnReady = func() {
		waitModifiersReleased(5 * time.Second)
		a.mu.Lock()
		paused := a.userPaused
		a.mu.Unlock()
		if !paused {
			job.SetPaused(false)
		}
	}
	job.OnProgress = func(done, total int) {
		a.emit(map[string]interface{}{"type": "progress", "done": done, "total": total})
	}
	a.job = job
	a.userPaused = false

	go func() {
		err := job.Run(input)
		a.mu.Lock()
		if a.job == job {
			a.job = nil
		}
		a.mu.Unlock()
		event := map[string]interface{}{"type": "finished", "reason": "done"}
		switch {
		case errors.Is(err, engine.ErrStopped):
			event["reason"] = "stopped"
		case err != nil:
			event["reason"] = "error"
			event["message"] = err.Error()
		}
		a.emit(event)
	}()
	return nil
}
