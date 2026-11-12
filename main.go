// Mac Typer 命令行入口（macOS）。图形界面把同一个包编译成静态库（-buildmode=c-archive），
// 通过 bridge.go 导出的函数调用打字引擎，此时 main 函数不会执行。
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"mac-typer/internal/engine"
)

type options struct {
	text     string
	textFile string
	typoFile string
	stdin    io.Reader
	cfg      engine.Config
}

func main() {
	textFile := flag.String("text", "", "要输入的文本文件")
	text := flag.String("s", "", "要输入的文本")
	typoFile := flag.String("typos", "", "错词库文件，每行：错词=>正词")
	baseDelay := flag.Duration("delay", 80*time.Millisecond, "每次输入的基础间隔")
	jitter := flag.Duration("jitter", 60*time.Millisecond, "随机抖动范围，实际间隔为 delay 到 delay+jitter")
	countdown := flag.Int("countdown", 5, "开始前倒计时秒数")
	gui := flag.Bool("gui", false, "打开图形化配置窗口")
	readStdin := flag.Bool("stdin", false, "从标准输入读取要输入的文本（不会出现在进程列表中）")
	typoRate := flag.Float64("typo-rate", 1, "每处可匹配的词触发错词的概率，0–1")
	slipRate := flag.Float64("slip-rate", 0, "每个英文字母误按相邻键再改正的概率，0–1")
	natural := flag.Bool("natural", false, "自然节奏：标点和换行后停顿更久，词内连击更快，偶尔犹豫")
	flag.Parse()

	opts := options{
		text:     *text,
		textFile: *textFile,
		typoFile: *typoFile,
		cfg: engine.Config{
			Delay:     *baseDelay,
			Jitter:    *jitter,
			Countdown: *countdown,
			TypoRate:  *typoRate,
			SlipRate:  *slipRate,
			Natural:   *natural,
		},
	}
	if *readStdin {
		opts.stdin = os.Stdin
	}
	if *gui || flag.NFlag() == 0 {
		var err error
		opts, err = guiOptions(opts)
		if err != nil {
			exit(err)
		}
	}

	if err := run(opts, nativeSink{}); err != nil {
		exit(err)
	}
}

// prepare 校验配置、正文和错词库，全部通过后才返回可执行的任务。
func prepare(cfg engine.Config, input, typoFile string, sink engine.Sink) (*engine.Job, string, error) {
	if err := cfg.Validate(); err != nil {
		return nil, "", err
	}
	input, err := engine.PrepareInput(input)
	if err != nil {
		return nil, "", err
	}
	typos, err := engine.LoadTypos(typoFile)
	if err != nil {
		return nil, "", err
	}
	return engine.NewJob(cfg, typos, sink, time.Now().UnixNano()), input, nil
}

func run(opts options, sink engine.Sink) error {
	input, err := loadInput(opts.text, opts.textFile, opts.stdin)
	if err != nil {
		return err
	}
	j, input, err := prepare(opts.cfg, input, opts.typoFile, sink)
	if err != nil {
		return err
	}
	j.OnCountdown = func(n int) { fmt.Fprintf(os.Stderr, "%d...\n", n) }

	// 命令行模式下可用 kill -USR1 <pid> 暂停/继续。
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGUSR1)
	defer signal.Stop(ch)
	go func() {
		for range ch {
			j.TogglePause()
		}
	}()
	return j.Run(input)
}

func guiOptions(defaults options) (options, error) {
	text, err := prompt("要输入的文本", defaults.text)
	if err != nil {
		return options{}, err
	}
	typoFile, err := chooseFile("选择错词库文件（可取消）")
	if err != nil {
		return options{}, err
	}
	delay, err := promptDuration("基础间隔，例如 80ms", defaults.cfg.Delay)
	if err != nil {
		return options{}, err
	}
	jitter, err := promptDuration("随机抖动，例如 60ms", defaults.cfg.Jitter)
	if err != nil {
		return options{}, err
	}
	countdown, err := promptInt("开始前倒计时秒数", defaults.cfg.Countdown)
	if err != nil {
		return options{}, err
	}
	_, err = runAppleScript(`display dialog "设置完成。点好后请在倒计时内把光标放到目标输入框。" buttons {"开始"} default button "开始" with title "Mac Typer"`)
	if err != nil {
		return options{}, err
	}
	cfg := defaults.cfg
	cfg.Delay, cfg.Jitter, cfg.Countdown = delay, jitter, countdown
	return options{text: text, typoFile: typoFile, cfg: cfg}, nil
}

func prompt(title, value string) (string, error) {
	out, err := runAppleScript(`text returned of (display dialog ` + strconv.Quote(title) + ` default answer ` + strconv.Quote(value) + ` with title "Mac Typer")`)
	return strings.TrimSpace(out), err
}

func promptDuration(title string, value time.Duration) (time.Duration, error) {
	out, err := prompt(title, value.String())
	if err != nil {
		return 0, err
	}
	return time.ParseDuration(out)
}

func promptInt(title string, value int) (int, error) {
	out, err := prompt(title, strconv.Itoa(value))
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(out)
}

func chooseFile(title string) (string, error) {
	out, err := runAppleScript(`try
		POSIX path of (choose file with prompt ` + strconv.Quote(title) + `)
	on error number -128
		""
	end try`)
	return strings.TrimSpace(out), err
}

func runAppleScript(script string) (string, error) {
	out, err := exec.Command("osascript", "-e", script).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out)))
	}
	return strings.TrimSpace(string(out)), nil
}

func loadInput(text, path string, stdin io.Reader) (string, error) {
	if stdin != nil {
		b, err := io.ReadAll(stdin)
		if err != nil {
			return "", err
		}
		return string(b), nil
	}
	if text != "" {
		return text, nil
	}
	if path == "" {
		return "", nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func exit(err error) {
	fmt.Fprintln(os.Stderr, "错误：", err)
	os.Exit(1)
}
