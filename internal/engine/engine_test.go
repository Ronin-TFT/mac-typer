package engine

import (
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

func runJob(t *testing.T, cfg Config, typos []Typo, input string, seed int64) *recordSink {
	t.Helper()
	sink := &recordSink{}
	j := NewJob(cfg, typos, sink, seed)
	in, err := PrepareInput(input)
	if err != nil {
		t.Fatal(err)
	}
	if err := j.Run(in); err != nil {
		t.Fatal(err)
	}
	return sink
}

func TestTypoMatcher(t *testing.T) {
	m := newTypoMatcher([]Typo{
		{Wrong: "teh", Correct: "the"},
		{Wrong: "tehre", Correct: "there"},
		{Wrong: "adress", Correct: "address"},
		{Wrong: "你号", Correct: "你好"},
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
		if ok != tc.ok || got.Wrong != tc.want {
			t.Errorf("match(%q, %q) = %+v, %v; want %q, %v", tc.input, tc.prev, got, ok, tc.want, tc.ok)
		}
	}
}

func TestTypoMatcherCaseInsensitive(t *testing.T) {
	m := newTypoMatcher([]Typo{
		{Wrong: "teh", Correct: "the"},
		{Wrong: "iPhnoe", Correct: "iPhone"},
	})
	for _, tc := range []struct {
		input, wrong, correct string
		ok                    bool
	}{
		{"The end", "Teh", "The", true},
		{"THE END", "TEH", "THE", true},
		{"the end", "teh", "the", true},
		{"iPhone 15", "iPhnoe", "iPhone", true},
		{"iphone 15", "", "", false},
		{"Theory", "", "", false},
	} {
		got, ok := m.match(tc.input, 0)
		if ok != tc.ok || got.Wrong != tc.wrong || got.Correct != tc.correct {
			t.Errorf("match(%q) = %+v, %v; want %q/%q, %v", tc.input, got, ok, tc.wrong, tc.correct, tc.ok)
		}
	}
	s := runJob(t, Config{TypoRate: 1}, []Typo{{Wrong: "teh", Correct: "the"}}, "The cat. THE DOG.", 1)
	if s.result() != "The cat. THE DOG." || !strings.Contains(s.String(), "Teh") || !strings.Contains(s.String(), "TEH") {
		t.Fatalf("case-preserving typo failed: %q -> %q", s, s.result())
	}
}

func TestGateStartWaitsForReady(t *testing.T) {
	sink := &recordSink{}
	j := NewJob(Config{GateStart: true}, nil, sink, 1)
	ready := make(chan struct{})
	j.OnReady = func() { close(ready) }
	done := make(chan error, 1)
	go func() { done <- j.Run("abc") }()
	<-ready
	time.Sleep(100 * time.Millisecond)
	if sink.String() != "" {
		t.Fatalf("typed before ready was acknowledged: %q", sink)
	}
	j.SetPaused(false)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if sink.String() != "abc" {
		t.Fatalf("output = %q", sink)
	}
}

func TestCommonPrefixRunes(t *testing.T) {
	if got := commonPrefixRunes("motter", "mother"); got != 3 {
		t.Fatalf("commonPrefixRunes() = %d, want 3", got)
	}
}

func TestTypoRateAndBoundaries(t *testing.T) {
	typos := []Typo{{Wrong: "teh", Correct: "the"}}
	if s := runJob(t, Config{TypoRate: 0}, typos, "other the", 1); s.count("⌫") != 0 {
		t.Fatalf("rate 0 still produced typos: %q", s)
	}
	s := runJob(t, Config{TypoRate: 1}, typos, "other the", 1)
	if !strings.HasPrefix(s.String(), "other teh") || s.result() != "other the" {
		t.Fatalf("unexpected typing %q -> %q", s, s.result())
	}
}

func TestSlipsAlwaysEndCorrect(t *testing.T) {
	input := "The quick brown fox, jumps over the lazy dog.\n你好 World"
	for seed := int64(0); seed < 50; seed++ {
		s := runJob(t, Config{SlipRate: 0.5, TypoRate: 1, Natural: true},
			[]Typo{{Wrong: "teh", Correct: "the"}}, input, seed)
		if s.result() != input {
			t.Fatalf("seed %d: result %q", seed, s.result())
		}
	}
	s := runJob(t, Config{SlipRate: 1}, nil, "ab", 3)
	if s.count("⌫") == 0 {
		t.Fatalf("slip rate 1 produced no corrections: %q", s)
	}
	if s := runJob(t, Config{SlipRate: 1}, nil, "你好，123", 3); s.count("⌫") != 0 {
		t.Fatalf("slips must only affect ASCII letters: %q", s)
	}
}

func TestNeighborKeyPreservesCase(t *testing.T) {
	j := NewJob(Config{}, nil, NopSink{}, 1)
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
	plain := runJob(t, Config{}, nil, "Hello, world.", 1)
	natural := runJob(t, Config{Natural: true}, nil, "Hello, world.", 1)
	if plain.String() != natural.String() {
		t.Fatalf("natural rhythm changed keys: %q vs %q", plain, natural)
	}
}

func TestNormalizesNewlines(t *testing.T) {
	s := runJob(t, Config{}, nil, "a\r\nb\rc", 1)
	if s.String() != "a\nb\nc" {
		t.Fatalf("output = %q", s)
	}
}

func TestProgressAndCountdown(t *testing.T) {
	sink := &recordSink{}
	j := NewJob(Config{SlipRate: 1}, []Typo{{Wrong: "你号", Correct: "你好"}}, sink, 1)
	var progress [][2]int
	j.OnProgress = func(done, total int) { progress = append(progress, [2]int{done, total}) }
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
	j := NewJob(Config{Delay: time.Millisecond}, nil, sink, 1)
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
		if err != ErrStopped {
			t.Fatalf("Run() = %v, want ErrStopped", err)
		}
	case <-time.After(time.Second):
		t.Fatal("stop did not interrupt typing")
	}
	if got := sink.count("x"); got <= 2 || got == 50 {
		t.Fatalf("typed %d keys; expected to resume and then stop early", got)
	}
}

func TestStopInterruptsCountdownAndLongDelay(t *testing.T) {
	for _, cfg := range []Config{{Countdown: 3600}, {Delay: time.Minute}} {
		j := NewJob(cfg, nil, NopSink{}, 1)
		done := make(chan error, 1)
		go func() { done <- j.Run("abc") }()
		time.Sleep(20 * time.Millisecond)
		j.Stop()
		select {
		case err := <-done:
			if err != ErrStopped {
				t.Fatalf("Run() = %v", err)
			}
		case <-time.After(time.Second):
			t.Fatalf("stop did not interrupt %+v", cfg)
		}
	}
}
