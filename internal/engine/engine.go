// Package engine 是 Mac Typer 的打字引擎：节奏、错词、手误、暂停/结束与进度。
// 与平台无关，按键由调用方提供的 Sink 发送。
package engine

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"math"
	"math/rand"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode"
	"unicode/utf8"
)

// Sink 接收引擎产生的按键。正式运行时由系统键盘事件实现，测试时记录下来。
type Sink interface {
	Text(s string) error
	Backspace() error
}

// NopSink 丢弃所有按键，用于图形界面的集成测试。
type NopSink struct{}

func (NopSink) Text(string) error { return nil }
func (NopSink) Backspace() error  { return nil }

type Config struct {
	Delay     time.Duration
	Jitter    time.Duration
	Countdown int
	TypoRate  float64 // 每处可匹配的词使用错词规则的概率
	SlipRate  float64 // 每个英文字母误按相邻键的概率
	Natural   bool    // 自然节奏
	GateStart bool    // 倒计时结束后先暂停并调用 onReady，由调用方准备好（如切换输入法）后继续
}

func (c Config) Validate() error {
	if c.Delay < 0 || c.Delay > time.Minute || c.Jitter < 0 || c.Jitter > time.Minute {
		return fmt.Errorf("间隔和抖动须在 0–60 秒之间")
	}
	if c.Countdown < 0 || c.Countdown > 3600 {
		return fmt.Errorf("倒计时须在 0–3600 秒之间")
	}
	if !validRate(c.TypoRate) {
		return fmt.Errorf("错词概率须在 0–1 之间")
	}
	if !validRate(c.SlipRate) {
		return fmt.Errorf("手误概率须在 0–1 之间")
	}
	return nil
}

func validRate(v float64) bool { return !math.IsNaN(v) && v >= 0 && v <= 1 }

// Typo 是一条错词规则：先输入 Wrong，再改成 Correct。
type Typo struct {
	Wrong   string
	Correct string
}

// PrepareInput 检查正文并统一换行符。
func PrepareInput(input string) (string, error) {
	if strings.TrimSpace(input) == "" {
		return "", fmt.Errorf("没有可输入内容")
	}
	if !utf8.ValidString(input) {
		return "", fmt.Errorf("输入文本不是有效 UTF-8")
	}
	return NormalizeNewlines(input), nil
}

// NormalizeNewlines 把 \r\n 和 \r 统一为 \n。
func NormalizeNewlines(s string) string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	return strings.ReplaceAll(s, "\r", "\n")
}

// LoadTypos 读取错词库文件；path 为空时返回空规则。
func LoadTypos(path string) ([]Typo, error) {
	if path == "" {
		return nil, nil
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return ParseTypos(f)
}

// ParseTypos 解析错词库：每行“错词=>正词”，# 开头为注释。
func ParseTypos(r io.Reader) ([]Typo, error) {
	var out []Typo
	scanner := bufio.NewScanner(r)
	lineNumber := 0
	for scanner.Scan() {
		lineNumber++
		line := strings.TrimSpace(scanner.Text())
		if lineNumber == 1 {
			line = strings.TrimPrefix(line, "\uFEFF")
		}
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
		out = append(out, Typo{Wrong: wrong, Correct: correct})
	}
	return out, scanner.Err()
}

// ErrStopped 表示任务被 Stop 结束。
var ErrStopped = errors.New("已结束")

// Job 是一次键入任务。Run 在调用方的 goroutine 中执行；Stop 和 SetPaused
// 可以从任意 goroutine 调用。
type Job struct {
	cfg     Config
	sink    Sink
	matcher *typoMatcher
	r       *rand.Rand

	paused   atomic.Bool
	stop     chan struct{}
	stopOnce sync.Once

	OnCountdown func(seconds int)
	OnReady     func()
	OnProgress  func(done, total int)

	done, total int
	prev        rune // 已消耗的上一个原文字符，用于词边界判断
	lastTyped   rune // 上一个实际按下的字符，用于节奏计算
}

func NewJob(cfg Config, typos []Typo, sink Sink, seed int64) *Job {
	return &Job{
		cfg:     cfg,
		sink:    sink,
		matcher: newTypoMatcher(typos),
		r:       rand.New(rand.NewSource(seed)),
		stop:    make(chan struct{}),
	}
}

func (j *Job) Stop()            { j.stopOnce.Do(func() { close(j.stop) }) }
func (j *Job) SetPaused(p bool) { j.paused.Store(p) }
func (j *Job) Paused() bool     { return j.paused.Load() }
func (j *Job) TogglePause() (now bool) {
	for {
		old := j.paused.Load()
		if j.paused.CompareAndSwap(old, !old) {
			return !old
		}
	}
}

func (j *Job) checkStop() error {
	select {
	case <-j.stop:
		return ErrStopped
	default:
		return nil
	}
}

// sleep 等待 d，期间可被 Stop 立即打断。
func (j *Job) sleep(d time.Duration) error {
	if d <= 0 {
		return j.checkStop()
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-j.stop:
		return ErrStopped
	case <-t.C:
		return nil
	}
}

func (j *Job) waitIfPaused() error {
	for j.paused.Load() {
		if err := j.sleep(50 * time.Millisecond); err != nil {
			return err
		}
	}
	return j.checkStop()
}

// Run 执行倒计时并输入 input。input 应已经过 prepareInput 处理。
func (j *Job) Run(input string) error {
	j.total = utf8.RuneCountInString(input)
	for i := j.cfg.Countdown; i > 0; i-- {
		if err := j.waitIfPaused(); err != nil {
			return err
		}
		if j.OnCountdown != nil {
			j.OnCountdown(i)
		}
		if err := j.sleep(time.Second); err != nil {
			return err
		}
	}
	if j.cfg.GateStart && j.OnReady != nil {
		j.SetPaused(true)
		j.OnReady()
		if err := j.waitIfPaused(); err != nil {
			return err
		}
	}
	j.reportProgress()
	for len(input) > 0 {
		if err := j.waitIfPaused(); err != nil {
			return err
		}
		n, err := j.step(input)
		if err != nil {
			return err
		}
		input = input[n:]
	}
	return nil
}

func (j *Job) reportProgress() {
	if j.OnProgress != nil {
		j.OnProgress(j.done, j.total)
	}
}

// advance 记录已完成输入的原文片段。
func (j *Job) advance(consumed string) {
	j.done += utf8.RuneCountInString(consumed)
	j.prev, _ = utf8.DecodeLastRuneInString(consumed)
	j.reportProgress()
}

// step 输入 input 开头的一段内容，返回消耗的字节数。
func (j *Job) step(input string) (int, error) {
	if t, ok := j.matcher.match(input, j.prev); ok {
		var err error
		if j.r.Float64() < j.cfg.TypoRate {
			err = j.typeTypo(t)
		} else {
			err = j.typeString(t.Correct)
		}
		if err != nil {
			return 0, err
		}
		j.advance(t.Correct)
		return len(t.Correct), nil
	}

	ch, size := utf8.DecodeRuneInString(input)
	if ch == utf8.RuneError && size == 1 {
		return 0, fmt.Errorf("输入文本不是有效 UTF-8")
	}
	if j.cfg.SlipRate > 0 && isSlipCandidate(ch) && j.r.Float64() < j.cfg.SlipRate {
		return j.typeSlip(input, size)
	}
	if err := j.typeRune(ch); err != nil {
		return 0, err
	}
	j.advance(input[:size])
	return size, nil
}

func (j *Job) typeRune(ch rune) error {
	if err := j.waitIfPaused(); err != nil {
		return err
	}
	if err := j.sink.Text(string(ch)); err != nil {
		return err
	}
	d := j.interval(ch)
	j.lastTyped = ch
	return j.sleep(d)
}

func (j *Job) typeString(s string) error {
	for _, ch := range s {
		if err := j.typeRune(ch); err != nil {
			return err
		}
	}
	return nil
}

func (j *Job) backspace(n int) error {
	for i := 0; i < n; i++ {
		if err := j.waitIfPaused(); err != nil {
			return err
		}
		if err := j.sink.Backspace(); err != nil {
			return err
		}
		if err := j.sleep(j.backspaceInterval()); err != nil {
			return err
		}
	}
	return nil
}

// typeTypo 先输入错词，再删除整个错词或只删除错误部分，最后补上正词。
func (j *Job) typeTypo(t Typo) error {
	if err := j.typeString(t.Wrong); err != nil {
		return err
	}
	if err := j.sleep(j.reactionDelay()); err != nil {
		return err
	}
	prefix := commonPrefixRunes(t.Wrong, t.Correct)
	deleteRunes := utf8.RuneCountInString(t.Wrong)
	retype := t.Correct
	if prefix > 0 && j.r.Intn(2) == 0 {
		deleteRunes -= prefix
		retype = string([]rune(t.Correct)[prefix:])
	}
	if err := j.backspace(deleteRunes); err != nil {
		return err
	}
	return j.typeString(retype)
}

// typeSlip 误按相邻键；有时会多打一个字母才发现，然后删除并改正。
func (j *Job) typeSlip(input string, size int) (int, error) {
	ch, _ := utf8.DecodeRuneInString(input)
	consumed := input[:size]
	typed := 1
	if err := j.typeRune(neighborKey(ch, j.r)); err != nil {
		return 0, err
	}
	if next, nsize := utf8.DecodeRuneInString(input[size:]); nsize > 0 && isSlipCandidate(next) && j.r.Float64() < 0.4 {
		if err := j.typeRune(next); err != nil {
			return 0, err
		}
		consumed = input[:size+nsize]
		typed++
	}
	if err := j.sleep(j.reactionDelay()); err != nil {
		return 0, err
	}
	if err := j.backspace(typed); err != nil {
		return 0, err
	}
	if err := j.typeString(consumed); err != nil {
		return 0, err
	}
	j.advance(consumed)
	return len(consumed), nil
}

func (j *Job) baseInterval() time.Duration {
	d := j.cfg.Delay
	if j.cfg.Jitter > 0 {
		d += time.Duration(j.r.Int63n(int64(j.cfg.Jitter)))
	}
	return d
}

// interval 返回按下 typed 之后到下一个按键的等待时间。
func (j *Job) interval(typed rune) time.Duration {
	d := j.baseInterval()
	if !j.cfg.Natural {
		return d
	}
	f := math.Exp(j.r.NormFloat64()*0.25) * rhythmFactor(j.lastTyped, typed)
	if j.r.Float64() < 0.01 {
		f += 3 // 偶尔犹豫
	}
	return time.Duration(float64(d) * f)
}

func (j *Job) backspaceInterval() time.Duration {
	d := j.baseInterval()
	if !j.cfg.Natural {
		return d
	}
	return time.Duration(float64(d) * 0.75 * math.Exp(j.r.NormFloat64()*0.2))
}

// reactionDelay 是打错后发现错误的停顿。
func (j *Job) reactionDelay() time.Duration {
	d := j.baseInterval()
	if !j.cfg.Natural {
		return d
	}
	return time.Duration(float64(d) * (2 + j.r.Float64()*2))
}

func rhythmFactor(prev, typed rune) float64 {
	switch {
	case typed == '\n':
		return 3
	case strings.ContainsRune(".!?。！？…", typed):
		return 2.5
	case strings.ContainsRune(",;:，、；：", typed):
		return 1.6
	case typed == ' ':
		return 1.2
	case unicode.IsLetter(typed) && unicode.IsLetter(prev):
		return 0.85 // 词内连击
	default:
		return 1
	}
}

var qwertyNeighbors = map[rune]string{
	'q': "wa", 'w': "qeas", 'e': "wrsd", 'r': "etdf", 't': "ryfg", 'y': "tugh", 'u': "yihj", 'i': "uojk", 'o': "ipkl", 'p': "ol",
	'a': "qwsz", 's': "awedxz", 'd': "serfcx", 'f': "drtgvc", 'g': "ftyhbv", 'h': "gyujnb", 'j': "huikmn", 'k': "jiolm", 'l': "kop",
	'z': "asx", 'x': "zsdc", 'c': "xdfv", 'v': "cfgb", 'b': "vghn", 'n': "bhjm", 'm': "njk",
}

func isSlipCandidate(ch rune) bool {
	return ch < utf8.RuneSelf && qwertyNeighbors[unicode.ToLower(ch)] != ""
}

func neighborKey(ch rune, r *rand.Rand) rune {
	n := qwertyNeighbors[unicode.ToLower(ch)]
	w := rune(n[r.Intn(len(n))])
	if unicode.IsUpper(ch) {
		w = unicode.ToUpper(w)
	}
	return w
}

func commonPrefixRunes(a, b string) int {
	ar, br := []rune(a), []rune(b)
	n := 0
	for n < len(ar) && n < len(br) && ar[n] == br[n] {
		n++
	}
	return n
}

// typoMatcher 按首字符（小写）索引错词规则，同一首字符下优先匹配最长的正词。
// 全小写的规则不区分大小写，例如 the 也会命中 The、THE，并按原文大小写打出错词。
type typoMatcher struct {
	byFirst map[rune][]typoRule
}

type typoRule struct {
	Typo
	fold  bool // 规则全为小写，匹配时忽略大小写
	runes int
}

func newTypoMatcher(typos []Typo) *typoMatcher {
	m := &typoMatcher{byFirst: make(map[rune][]typoRule)}
	for _, t := range typos {
		first, _ := utf8.DecodeRuneInString(t.Correct)
		rule := typoRule{Typo: t, fold: t.Correct == strings.ToLower(t.Correct), runes: utf8.RuneCountInString(t.Correct)}
		key := unicode.ToLower(first)
		m.byFirst[key] = append(m.byFirst[key], rule)
	}
	for _, list := range m.byFirst {
		sort.SliceStable(list, func(i, j int) bool { return list[i].runes > list[j].runes })
	}
	return m
}

// match 返回 input 开头可以使用的错词规则，correct 为原文中的实际片段。
// prev 是已输入的上一个字符，用于避免命中单词内部，例如规则 the 不会命中 other 或 there。
func (m *typoMatcher) match(input string, prev rune) (Typo, bool) {
	if m == nil || len(m.byFirst) == 0 {
		return Typo{}, false
	}
	first, _ := utf8.DecodeRuneInString(input)
	for _, rule := range m.byFirst[unicode.ToLower(first)] {
		segment, ok := rule.prefixOf(input)
		if ok && atWordBoundary(prev, segment, input[len(segment):]) {
			return Typo{Wrong: adaptCase(rule.Wrong, segment), Correct: segment}, true
		}
	}
	return Typo{}, false
}

func (r typoRule) prefixOf(input string) (string, bool) {
	if strings.HasPrefix(input, r.Correct) {
		return r.Correct, true
	}
	if !r.fold {
		return "", false
	}
	end, n := 0, 0
	for end < len(input) && n < r.runes {
		_, size := utf8.DecodeRuneInString(input[end:])
		end += size
		n++
	}
	if n == r.runes && strings.EqualFold(input[:end], r.Correct) {
		return input[:end], true
	}
	return "", false
}

// adaptCase 让错词跟随原文大小写：全大写的词整体大写，首字母大写的词首字母大写。
func adaptCase(wrong, original string) string {
	letters, upper := 0, 0
	for _, r := range original {
		if unicode.IsLetter(r) {
			letters++
			if unicode.IsUpper(r) {
				upper++
			}
		}
	}
	switch {
	case letters >= 2 && upper == letters:
		return strings.ToUpper(wrong)
	case letters > 0:
		first, _ := utf8.DecodeRuneInString(original)
		if unicode.IsUpper(first) {
			w, size := utf8.DecodeRuneInString(wrong)
			return string(unicode.ToUpper(w)) + wrong[size:]
		}
	}
	return wrong
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
