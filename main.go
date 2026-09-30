package main

import (
	"bufio"
	"flag"
	"fmt"
	"math/rand"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
	"unicode/utf8"
)

type typo struct {
	wrong   string
	correct string
}

var paused atomic.Bool
var eventStream bool

func main() {
	textFile := flag.String("text", "", "要输入的文本文件")
	text := flag.String("s", "", "要输入的文本")
	typoFile := flag.String("typos", "", "错词库文件，每行：错词=>正词")
	baseDelay := flag.Duration("delay", 80*time.Millisecond, "每次输入的基础间隔")
	jitter := flag.Duration("jitter", 60*time.Millisecond, "随机抖动范围，实际间隔为 delay 到 delay+jitter")
	countdown := flag.Int("countdown", 5, "开始前倒计时秒数")
	gui := flag.Bool("gui", false, "打开图形化配置窗口")
	stream := flag.Bool("event-stream", false, "把键盘事件输出给图形应用")
	flag.Parse()
	eventStream = *stream

	opts := options{
		text:      *text,
		textFile:  *textFile,
		typoFile:  *typoFile,
		delay:     *baseDelay,
		jitter:    *jitter,
		countdown: *countdown,
	}
	if *gui || flag.NFlag() == 0 {
		var err error
		opts, err = guiOptions(opts)
		if err != nil {
			exit(err)
		}
	}

	if err := run(opts); err != nil {
		exit(err)
	}
}

type options struct {
	text      string
	textFile  string
	typoFile  string
	delay     time.Duration
	jitter    time.Duration
	countdown int
}

func run(opts options) error {
	if opts.delay < 0 || opts.delay > time.Minute || opts.jitter < 0 || opts.jitter > time.Minute || opts.countdown < 0 || opts.countdown > 3600 {
		return fmt.Errorf("间隔和抖动须在 0–60 秒之间，倒计时须在 0–3600 秒之间")
	}
	input, err := loadInput(opts.text, opts.textFile)
	if err != nil {
		return err
	}
	if strings.TrimSpace(input) == "" {
		return fmt.Errorf("没有可输入内容，请使用 -s 或 -text")
	}
	if !utf8.ValidString(input) {
		return fmt.Errorf("输入文本不是有效 UTF-8")
	}

	typos, err := loadTypos(opts.typoFile)
	if err != nil {
		return err
	}
	handleSignals()

	for i := opts.countdown; i > 0; i-- {
		fmt.Printf("%d...\n", i)
		time.Sleep(time.Second)
	}

	r := rand.New(rand.NewSource(time.Now().UnixNano()))
	return typeText(input, typos, opts.delay, opts.jitter, r)
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
	delay, err := promptDuration("基础间隔，例如 80ms", defaults.delay)
	if err != nil {
		return options{}, err
	}
	jitter, err := promptDuration("随机抖动，例如 60ms", defaults.jitter)
	if err != nil {
		return options{}, err
	}
	countdown, err := promptInt("开始前倒计时秒数", defaults.countdown)
	if err != nil {
		return options{}, err
	}
	_, err = runAppleScript(`display dialog "设置完成。点好后请在倒计时内把光标放到目标输入框。" buttons {"开始"} default button "开始" with title "Mac Typer"`)
	if err != nil {
		return options{}, err
	}
	return options{text: text, typoFile: typoFile, delay: delay, jitter: jitter, countdown: countdown}, nil
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

func loadInput(text, path string) (string, error) {
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

func loadTypos(path string) ([]typo, error) {
	if path == "" {
		return nil, nil
	}

	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var out []typo
	scanner := bufio.NewScanner(f)
	lineNumber := 0
	for scanner.Scan() {
		lineNumber++
		line := strings.TrimSpace(scanner.Text())
		if !utf8.ValidString(line) {
			return nil, fmt.Errorf("错词库第 %d 行不是有效 UTF-8", lineNumber)
		}
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		parts := strings.Split(line, "=>")
		if len(parts) != 2 {
			return nil, fmt.Errorf("错词库格式错误：%q，应该是 错词=>正词", line)
		}

		wrong := strings.TrimSpace(parts[0])
		correct := strings.TrimSpace(parts[1])
		if wrong == "" || correct == "" {
			return nil, fmt.Errorf("错词库不能有空词：%q", line)
		}
		out = append(out, typo{wrong: wrong, correct: correct})
	}
	return out, scanner.Err()
}

func typeText(input string, typos []typo, delay, jitter time.Duration, r *rand.Rand) error {
	for len(input) > 0 {
		waitIfPaused()
		if t, ok := nextTypo(input, typos); ok {
			used, err := typeTypo(t, delay, jitter, r)
			if err != nil {
				return err
			}
			input = input[used:]
			continue
		}

		ch, size := utf8.DecodeRuneInString(input)
		if ch == utf8.RuneError && size == 1 {
			return fmt.Errorf("输入文本不是有效 UTF-8")
		}
		if err := keystroke(string(ch)); err != nil {
			return err
		}
		pause(delay, jitter, r)
		input = input[size:]
	}
	return nil
}

func typeTypo(t typo, delay, jitter time.Duration, r *rand.Rand) (int, error) {
	if err := typeRunes(t.wrong, delay, jitter, r); err != nil {
		return 0, err
	}
	pause(delay, jitter, r)

	prefix := commonPrefixRunes(t.wrong, t.correct)
	deleteRunes := utf8.RuneCountInString(t.wrong)
	retype := t.correct
	if prefix > 0 && r.Intn(2) == 0 {
		deleteRunes -= prefix
		retype = string([]rune(t.correct)[prefix:])
	}
	if err := backspaceRunes(deleteRunes, delay, jitter, r); err != nil {
		return 0, err
	}
	return len(t.correct), typeRunes(retype, delay, jitter, r)
}

func commonPrefixRunes(a, b string) int {
	ar, br := []rune(a), []rune(b)
	n := 0
	for n < len(ar) && n < len(br) && ar[n] == br[n] {
		n++
	}
	return n
}

func nextTypo(input string, typos []typo) (typo, bool) {
	for _, t := range typos {
		if strings.HasPrefix(input, t.correct) {
			return t, true
		}
	}
	return typo{}, false
}

func typeRunes(s string, delay, jitter time.Duration, r *rand.Rand) error {
	for _, ch := range s {
		waitIfPaused()
		if err := keystroke(string(ch)); err != nil {
			return err
		}
		pause(delay, jitter, r)
	}
	return nil
}

func handleSignals() {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGUSR1)
	go func() {
		for range ch {
			paused.Store(!paused.Load())
		}
	}()
}

func waitIfPaused() {
	for paused.Load() {
		time.Sleep(100 * time.Millisecond)
	}
}

func pause(delay, jitter time.Duration, r *rand.Rand) {
	if jitter <= 0 {
		time.Sleep(delay)
		return
	}
	time.Sleep(delay + time.Duration(r.Int63n(int64(jitter))))
}

func backspaceRunes(n int, delay, jitter time.Duration, r *rand.Rand) error {
	for i := 0; i < n; i++ {
		waitIfPaused()
		if err := sendBackspace(1); err != nil {
			return err
		}
		pause(delay, jitter, r)
	}
	return nil
}

func exit(err error) {
	fmt.Fprintln(os.Stderr, "错误：", err)
	os.Exit(1)
}
