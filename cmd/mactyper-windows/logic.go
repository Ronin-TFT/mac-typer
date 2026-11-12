// Mac Typer 的 Windows 版：WebView2 界面 + SendInput 发送按键，打字引擎与 macOS 版共用。
package main

import (
	"encoding/json"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"

	"mac-typer/internal/engine"
	"mac-typer/typos"
)

// version 与 macOS 版 Info.plist 中的版本一致，用于检查更新。
const version = "1.2.0"

const releaseAPI = "https://api.github.com/repos/Ronin-TFT/mac-typer/releases/latest"
const releasePagePrefix = "https://github.com/Ronin-TFT/mac-typer/"

// startRequest 是界面点击“开始”时传来的参数。
type startRequest struct {
	Text      string  `json:"text"`
	DelayMs   float64 `json:"delayMs"`
	JitterMs  float64 `json:"jitterMs"`
	Countdown float64 `json:"countdown"`
	TypoRate  float64 `json:"typoRate"` // 0–100
	SlipRate  float64 `json:"slipRate"` // 0–100
	Natural   bool    `json:"natural"`
	TypoMode  string  `json:"typoMode"` // none、builtin、custom
	TypoText  string  `json:"typoText"`
}

func finite(v float64) bool { return !math.IsNaN(v) && !math.IsInf(v, 0) }

// config 把界面参数转换为引擎配置并校验。
func (r startRequest) config() (engine.Config, error) {
	for _, v := range []float64{r.DelayMs, r.JitterMs, r.Countdown, r.TypoRate, r.SlipRate} {
		if !finite(v) {
			return engine.Config{}, fmt.Errorf("参数不是有效数字")
		}
	}
	if r.Countdown != math.Floor(r.Countdown) {
		return engine.Config{}, fmt.Errorf("倒计时须为整数秒")
	}
	cfg := engine.Config{
		Delay:     time.Duration(math.Round(r.DelayMs * float64(time.Millisecond))),
		Jitter:    time.Duration(math.Round(r.JitterMs * float64(time.Millisecond))),
		Countdown: int(r.Countdown),
		TypoRate:  r.TypoRate / 100,
		SlipRate:  r.SlipRate / 100,
		Natural:   r.Natural,
		GateStart: true, // 开始输入前等待用户松开修饰键
	}
	return cfg, cfg.Validate()
}

// typoRules 返回所选错词库的规则。
func (r startRequest) typoRules() ([]engine.Typo, error) {
	switch r.TypoMode {
	case "", "none":
		return nil, nil
	case "builtin":
		return engine.ParseTypos(strings.NewReader(typos.Common))
	case "custom":
		if strings.TrimSpace(r.TypoText) == "" {
			return nil, fmt.Errorf("请先选择错词库文件")
		}
		return engine.ParseTypos(strings.NewReader(r.TypoText))
	default:
		return nil, fmt.Errorf("未知的错词库类型：%s", r.TypoMode)
	}
}

// hotkey 是一个全局快捷键。Mods 使用 Win32 的 MOD_ALT(1)、MOD_CONTROL(2)、MOD_SHIFT(4)、MOD_WIN(8)。
type hotkey struct {
	VK   uint32 `json:"vk"`
	Mods uint32 `json:"mods"`
	Name string `json:"name"`
}

const (
	modAlt     = 0x1
	modControl = 0x2
	modShift   = 0x4
	modWin     = 0x8
)

var defaultHotkeys = []hotkey{
	{VK: 'B', Mods: modControl | modAlt, Name: "Ctrl+Alt+B"},
	{VK: 'N', Mods: modControl | modAlt, Name: "Ctrl+Alt+N"},
	{VK: 'M', Mods: modControl | modAlt, Name: "Ctrl+Alt+M"},
}

// validateHotkeys 检查三个快捷键（开始、暂停/继续、结束）都含 Ctrl、Alt 或 Win，且互不重复。
func validateHotkeys(keys []hotkey) error {
	if len(keys) != 3 {
		return fmt.Errorf("需要 3 个快捷键")
	}
	names := []string{"开始", "暂停/继续", "结束"}
	for i, k := range keys {
		if k.VK == 0 || k.VK > 0xFE {
			return fmt.Errorf("“%s”快捷键无效", names[i])
		}
		if k.Mods&(modAlt|modControl|modWin) == 0 {
			return fmt.Errorf("“%s”快捷键至少要包含 Ctrl、Alt 或 Win", names[i])
		}
		for j := 0; j < i; j++ {
			if keys[j].VK == k.VK && keys[j].Mods == k.Mods {
				return fmt.Errorf("“%s”与“%s”快捷键相同", names[i], names[j])
			}
		}
	}
	return nil
}

// compareVersions 比较 1.10.0 与 v1.9.2 这类版本号。
func compareVersions(a, b string) int {
	pa := strings.Split(strings.TrimPrefix(strings.TrimSpace(a), "v"), ".")
	pb := strings.Split(strings.TrimPrefix(strings.TrimSpace(b), "v"), ".")
	for i := 0; i < len(pa) || i < len(pb); i++ {
		var x, y int
		if i < len(pa) {
			x, _ = strconv.Atoi(pa[i])
		}
		if i < len(pb) {
			y, _ = strconv.Atoi(pb[i])
		}
		if x != y {
			if x < y {
				return -1
			}
			return 1
		}
	}
	return 0
}

// parseRelease 读取 GitHub latest release 的版本号与页面地址，并校验页面属于本仓库。
func parseRelease(data []byte) (string, string, error) {
	var release struct {
		TagName string `json:"tag_name"`
		HTMLURL string `json:"html_url"`
	}
	if err := json.Unmarshal(data, &release); err != nil {
		return "", "", err
	}
	if release.TagName == "" || !strings.HasPrefix(release.HTMLURL, releasePagePrefix) {
		return "", "", fmt.Errorf("无法识别的版本信息")
	}
	return strings.TrimPrefix(release.TagName, "v"), release.HTMLURL, nil
}
