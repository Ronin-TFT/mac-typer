package main

import (
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// recordSink 记录按键；文本按键原样追加，退格记为 ⌫。
type recordSink struct {
	mu   sync.Mutex
	keys []string
	hook func(n int)
}

func (s *recordSink) Text(t string) error { return s.add(t) }
func (s *recordSink) Backspace() error    { return s.add("⌫") }
func (s *recordSink) add(k string) error {
	s.mu.Lock()
	s.keys = append(s.keys, k)
	n := len(s.keys)
	hook := s.hook
	s.mu.Unlock()
	if hook != nil {
		hook(n)
	}
	return nil
}
func (s *recordSink) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return strings.Join(s.keys, "")
}

// result 按退格回放，得到目标输入框里最终的文字。
func (s *recordSink) result() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []rune
	for _, k := range s.keys {
		if k == "⌫" {
			if len(out) > 0 {
				out = out[:len(out)-1]
			}
			continue
		}
		out = append(out, []rune(k)...)
	}
	return string(out)
}

func (s *recordSink) count(k string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for _, x := range s.keys {
		if x == k {
			n++
		}
	}
	return n
}

func runJob(t *testing.T, cfg config, typos []typo, input string, seed int64) *recordSink {
	t.Helper()
	sink := &recordSink{}
	j := newJob(cfg, typos, sink, seed)
	in, err := prepareInput(input)
	if err != nil {
		t.Fatal(err)
	}
	if err := j.Run(in); err != nil {
		t.Fatal(err)
	}
	return sink
}

func TestInvalidInputEmitsNoEvents(t *testing.T) {
	sink := &recordSink{}
	for _, opts := range []options{
		{text: "hello", cfg: config{delay: -1}},
		{text: "hello", cfg: config{jitter: 61 * time.Second}},
		{text: "hello", cfg: config{countdown: -1}},
		{text: "hello", cfg: config{countdown: 3601}},
		{text: "hello", cfg: config{typoRate: -0.1}},
		{text: "hello", cfg: config{typoRate: 1.5}},
		{text: "hello", cfg: config{typoRate: math.NaN()}},
		{text: "hello", cfg: config{slipRate: 2}},
		{text: "valid prefix\xff"},
		{text: "   \n"},
	} {
		if err := run(opts, sink); err == nil {
			t.Fatalf("accepted invalid options: %+v", opts)
		}
	}
	path := filepath.Join(t.TempDir(), "invalid.txt")
	if err := os.WriteFile(path, []byte("hello\xff"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := run(options{textFile: path}, sink); err == nil {
		t.Fatal("accepted invalid file")
	}
	if sink.String() != "" {
		t.Fatalf("typed before validation: %q", sink.String())
	}
}

func TestInvalidTypoLibraryEmitsNoEvents(t *testing.T) {
	sink := &recordSink{}
	path := filepath.Join(t.TempDir(), "typos.txt")
	for _, contents := range []string{"mot\xff=>mother", "motter=>mother=>other", "=>mother", "motter=>", "the=>the"} {
		if err := os.WriteFile(path, []byte(contents), 0600); err != nil {
			t.Fatal(err)
		}
		if err := run(options{text: "mother", typoFile: path}, sink); err == nil {
			t.Fatalf("accepted invalid typo library: %q", contents)
		}
	}
	if sink.String() != "" {
		t.Fatalf("typed before validating typo library: %q", sink.String())
	}
}

func TestTypoMatcher(t *testing.T) {
	m := newTypoMatcher([]typo{
		{wrong: "teh", correct: "the"},
		{wrong: "tehre", correct: "there"},
		{wrong: "adress", correct: "address"},
		{wrong: "你号", correct: "你好"},
	})
	for _, tc := range []struct {
		input string
		prev  rune
		want  string
		ok    bool
	}{
		{"the address", 0, "teh", true},
		{"there is", ' ', "tehre", true},
		{"the", 'o', "", false},
		{"thereby", ' ', "", false},
		{"theory", 0, "", false},
		{"the.", ' ', "teh", true},
		{"你好世界", '说', "你号", true},
	} {
		got, ok := m.match(tc.input, tc.prev)
		if ok != tc.ok || got.wrong != tc.want {
			t.Errorf("match(%q, %q) = %+v, %v; want %q, %v", tc.input, tc.prev, got, ok, tc.want, tc.ok)
		}
	}
}

func TestCommonPrefixRunes(t *testing.T) {
	if got := commonPrefixRunes("motter", "mother"); got != 3 {
		t.Fatalf("commonPrefixRunes() = %d, want 3", got)
	}
}

func TestTypoRateAndBoundaries(t *testing.T) {
	typos := []typo{{wrong: "teh", correct: "the"}}
	if s := runJob(t, config{typoRate: 0}, typos, "other the", 1); s.count("⌫") != 0 {
		t.Fatalf("rate 0 still produced typos: %q", s)
	}
	s := runJob(t, config{typoRate: 1}, typos, "other the", 1)
	if !strings.HasPrefix(s.String(), "other teh") || s.result() != "other the" {
		t.Fatalf("unexpected typing %q -> %q", s, s.result())
	}
}

func TestSlipsAlwaysEndCorrect(t *testing.T) {
	input := "The quick brown fox, jumps over the lazy dog.\n你好 World"
	for seed := int64(0); seed < 50; seed++ {
		s := runJob(t, config{slipRate: 0.5, typoRate: 1, natural: true},
			[]typo{{wrong: "teh", correct: "the"}}, input, seed)
		if s.result() != input {
			t.Fatalf("seed %d: result %q", seed, s.result())
		}
	}
	s := runJob(t, config{slipRate: 1}, nil, "ab", 3)
	if s.count("⌫") == 0 {
		t.Fatalf("slip rate 1 produced no corrections: %q", s)
	}
	if s := runJob(t, config{slipRate: 1}, nil, "你好，123", 3); s.count("⌫") != 0 {
		t.Fatalf("slips must only affect ASCII letters: %q", s)
	}
}

func TestNeighborKeyPreservesCase(t *testing.T) {
	j := newJob(config{}, nil, nopSink{}, 1)
	for i := 0; i < 100; i++ {
		got := neighborKey('G', j.r)
		if !strings.ContainsRune("FTYHBV", got) {
			t.Fatalf("neighborKey('G') = %q", got)
		}
	}
}

func TestRhythmFactor(t *testing.T) {
	if rhythmFactor('a', '.') <= rhythmFactor('a', ' ') || rhythmFactor('a', 'b') >= 1 || rhythmFactor('a', '\n') < 2 {
		t.Fatal("rhythm factors out of order")
	}
	// 自然节奏只改变时间，不改变按键。
	plain := runJob(t, config{}, nil, "Hello, world.", 1)
	natural := runJob(t, config{natural: true}, nil, "Hello, world.", 1)
	if plain.String() != natural.String() {
		t.Fatalf("natural rhythm changed keys: %q vs %q", plain, natural)
	}
}

func TestNormalizesNewlines(t *testing.T) {
	s := runJob(t, config{}, nil, "a\r\nb\rc", 1)
	if s.String() != "a\nb\nc" {
		t.Fatalf("output = %q", s)
	}
}

func TestRunReadsStdin(t *testing.T) {
	sink := &recordSink{}
	if err := run(options{stdin: strings.NewReader("hi")}, sink); err != nil {
		t.Fatal(err)
	}
	if sink.String() != "hi" {
		t.Fatalf("output = %q", sink)
	}
}

func TestProgressAndCountdown(t *testing.T) {
	sink := &recordSink{}
	j := newJob(config{slipRate: 1}, []typo{{wrong: "你号", correct: "你好"}}, sink, 1)
	var progress [][2]int
	j.onProgress = func(done, total int) { progress = append(progress, [2]int{done, total}) }
	if err := j.Run("你好 ab"); err != nil {
		t.Fatal(err)
	}
	last := progress[len(progress)-1]
	if progress[0] != [2]int{0, 5} || last != [2]int{5, 5} {
		t.Fatalf("progress = %v", progress)
	}
	for i := 1; i < len(progress); i++ {
		if progress[i][0] < progress[i-1][0] {
			t.Fatalf("progress went backwards: %v", progress)
		}
	}
}

func TestPauseAndStop(t *testing.T) {
	sink := &recordSink{}
	j := newJob(config{delay: time.Millisecond}, nil, sink, 1)
	paused := make(chan struct{})
	sink.hook = func(n int) {
		if n == 2 {
			j.SetPaused(true)
			close(paused)
		}
	}
	done := make(chan error, 1)
	go func() { done <- j.Run(strings.Repeat("x", 50)) }()
	<-paused
	time.Sleep(100 * time.Millisecond)
	if got := sink.count("x"); got != 2 {
		t.Fatalf("typed %d keys while paused", got)
	}
	j.SetPaused(false)
	time.Sleep(10 * time.Millisecond)
	j.Stop()
	select {
	case err := <-done:
		if err != errStopped {
			t.Fatalf("Run() = %v, want errStopped", err)
		}
	case <-time.After(time.Second):
		t.Fatal("stop did not interrupt typing")
	}
	if got := sink.count("x"); got <= 2 || got == 50 {
		t.Fatalf("typed %d keys; expected to resume and then stop early", got)
	}
}

func TestStopInterruptsCountdownAndLongDelay(t *testing.T) {
	for _, cfg := range []config{{countdown: 3600}, {delay: time.Minute}} {
		j := newJob(cfg, nil, nopSink{}, 1)
		done := make(chan error, 1)
		go func() { done <- j.Run("abc") }()
		time.Sleep(20 * time.Millisecond)
		j.Stop()
		select {
		case err := <-done:
			if err != errStopped {
				t.Fatalf("Run() = %v", err)
			}
		case <-time.After(time.Second):
			t.Fatalf("stop did not interrupt %+v", cfg)
		}
	}
}
