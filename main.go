package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"math"
	"math/rand"
	"os"
	"os/exec"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
	"unicode"
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
	readStdin := flag.Bool("stdin", false, "从标准输入读取要输入的文本（不会出现在进程列表中）")
	typoRate := flag.Float64("typo-rate", 1, "每处可匹配的词触发错词的概率，0–1")
	flag.Parse()
	eventStream = *stream

	opts := options{
		text:      *text,
		textFile:  *textFile,
		typoFile:  *typoFile,
		delay:     *baseDelay,
		jitter:    *jitter,
		countdown: *countdown,
		typoRate:  *typoRate,
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
	typoRate  float64
	stdin     io.Reader
}

func run(opts options) error {
	if opts.delay < 0 || opts.delay > time.Minute || opts.jitter < 0 || opts.jitter > time.Minute || opts.countdown < 0 || opts.countdown > 3600 {
		return fmt.Errorf("间隔和抖动须在 0–60 秒之间，倒计时须在 0–3600 秒之间")
	}
	if math.IsNaN(opts.typoRate) || opts.typoRate < 0 || opts.typoRate > 1 {
		return fmt.Errorf("错词概率须在 0–1 之间")
	}
	input, err := loadInput(opts.text, opts.textFile, opts.stdin)
	if err != nil {
		return err
	}
	if strings.TrimSpace(input) == "" {
		return fmt.Errorf("没有可输入内容，请使用 -s、-text 或 -stdin")
	}
	if !utf8.ValidString(input) {
		return fmt.Errorf("输入文本不是有效 UTF-8")
	}
	input = normalizeNewlines(input)

	typos, err := loadTypos(opts.typoFile)
	if err != nil {
		return err
	}
	handleSignals()

	for i := opts.countdown; i > 0; i-- {
		if err := countdownTick(i); err != nil {
			return err
		}
		time.Sleep(time.Second)
	}

	r := rand.New(rand.NewSource(time.Now().UnixNano()))
	return typeText(input, newTypoMatcher(typos), opts.typoRate, opts.delay, opts.jitter, r)
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
	return options{text: text, typoFile: typoFile, delay: delay, jitter: jitter, countdown: countdown, typoRate: defaults.typoRate}, nil
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
		if wrong == correct {
			return nil, fmt.Errorf("错词库第 %d 行错词与正词相同：%q", lineNumber, line)
		}
		out = append(out, typo{wrong: wrong, correct: correct})
	}
	return out, scanner.Err()
}

func normalizeNewlines(s string) string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	return strings.ReplaceAll(s, "\r", "\n")
}

func typeText(input string, matcher *typoMatcher, rate float64, delay, jitter time.Duration, r *rand.Rand) error {
	var prev rune
	for len(input) > 0 {
		waitIfPaused()
		if t, ok := matcher.match(input, prev); ok {
			if r.Float64() < rate {
				if _, err := typeTypo(t, delay, jitter, r); err != nil {
					return err
				}
			} else if err := typeRunes(t.correct, delay, jitter, r); err != nil {
				return err
			}
			prev, _ = utf8.DecodeLastRuneInString(t.correct)
			input = input[len(t.correct):]
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
		prev = ch
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

// typoMatcher 按首字符索引错词规则，同一首字符下优先匹配最长的正词。
type typoMatcher struct {
	byFirst map[rune][]typo
}

func newTypoMatcher(typos []typo) *typoMatcher {
	m := &typoMatcher{byFirst: make(map[rune][]typo)}
	for _, t := range typos {
		first, _ := utf8.DecodeRuneInString(t.correct)
		m.byFirst[first] = append(m.byFirst[first], t)
	}
	for _, list := range m.byFirst {
		sort.SliceStable(list, func(i, j int) bool { return len(list[i].correct) > len(list[j].correct) })
	}
	return m
}

// match 返回 input 开头可以使用的错词规则。prev 是已输入的上一个字符，
// 用于避免命中单词内部，例如规则 the 不会命中 other 或 there。
func (m *typoMatcher) match(input string, prev rune) (typo, bool) {
	if m == nil || len(m.byFirst) == 0 {
		return typo{}, false
	}
	first, _ := utf8.DecodeRuneInString(input)
	for _, t := range m.byFirst[first] {
		if strings.HasPrefix(input, t.correct) && atWordBoundary(prev, t.correct, input[len(t.correct):]) {
			return t, true
		}
	}
	return typo{}, false
}

func atWordBoundary(prev rune, word, rest string) bool {
	first, _ := utf8.DecodeRuneInString(word)
	if isSpacedWordRune(first) && isSpacedWordRune(prev) {
		return false
	}
	last, _ := utf8.DecodeLastRuneInString(word)
	next, _ := utf8.DecodeRuneInString(rest)
	return !(isSpacedWordRune(last) && isSpacedWordRune(next))
}

// isSpacedWordRune 判断字符是否属于用空格分词的文字。中文、日文、泰文
// 没有空格分词，这类字符不做词边界限制。
func isSpacedWordRune(r rune) bool {
	if r == 0 || r == utf8.RuneError {
		return false
	}
	if unicode.In(r, unicode.Han, unicode.Hiragana, unicode.Katakana, unicode.Thai) {
		return false
	}
	return unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' || unicode.Is(unicode.Mn, r)
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
