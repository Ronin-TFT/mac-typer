package main

import (
	"bytes"
	"math"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestInvalidInputEmitsNoEvents(t *testing.T) {
	oldStream, oldWriter := eventStream, eventWriter
	defer func() { eventStream, eventWriter = oldStream, oldWriter }()
	eventStream = true
	var output bytes.Buffer
	eventWriter = &output
	for _, opts := range []options{
		{text: "hello", delay: -1},
		{text: "hello", jitter: 61 * time.Second},
		{text: "hello", countdown: -1},
		{text: "hello", countdown: 3601},
		{text: "valid prefix\xff"},
		{text: "hello", typoRate: -0.1},
		{text: "hello", typoRate: 1.5},
		{text: "hello", typoRate: math.NaN()},
	} {
		if err := run(opts); err == nil {
			t.Fatalf("accepted invalid options: %+v", opts)
		}
	}
	path := filepath.Join(t.TempDir(), "invalid.txt")
	if err := os.WriteFile(path, []byte("hello\xff"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := run(options{textFile: path}); err == nil {
		t.Fatal("accepted invalid file")
	}
	if output.Len() != 0 {
		t.Fatalf("typed before validation: %q", output.String())
	}
}

type pauseAfterFirstWrite struct {
	bytes.Buffer
	first chan struct{}
}

func (w *pauseAfterFirstWrite) Write(p []byte) (int, error) {
	n, err := w.Buffer.Write(p)
	if w.Buffer.String() == "B1\n" {
		paused.Store(true)
		close(w.first)
	}
	return n, err
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

func captureEvents(t *testing.T) *bytes.Buffer {
	t.Helper()
	oldStream, oldWriter := eventStream, eventWriter
	t.Cleanup(func() { eventStream, eventWriter = oldStream, oldWriter })
	eventStream = true
	var output bytes.Buffer
	eventWriter = &output
	return &output
}

func TestTypeTextHonoursRateAndBoundaries(t *testing.T) {
	m := newTypoMatcher([]typo{{wrong: "teh", correct: "the"}})
	output := captureEvents(t)
	if err := typeText("other the", m, 0, 0, 0, rand.New(rand.NewSource(1))); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(output.String(), "B") {
		t.Fatalf("rate 0 still produced typos: %q", output.String())
	}
	output.Reset()
	if err := typeText("other the", m, 1, 0, 0, rand.New(rand.NewSource(1))); err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(output.String(), "B1"); got < 1 || got > 3 {
		t.Fatalf("expected exactly one typo correction for the standalone word, got %q", output.String())
	}
	if !strings.HasPrefix(output.String(), strings.Join([]string{
		encodeTextEvent("o"), encodeTextEvent("t"), encodeTextEvent("h"),
	}, "\n")) {
		t.Fatalf("typo was applied inside \"other\": %q", output.String())
	}
}

func TestRunReadsStdinAndNormalizesNewlines(t *testing.T) {
	output := captureEvents(t)
	if err := run(options{stdin: strings.NewReader("a\r\nb\rc"), typoRate: 1}); err != nil {
		t.Fatal(err)
	}
	want := strings.Join([]string{
		encodeTextEvent("a"), encodeTextEvent("\n"), encodeTextEvent("b"), encodeTextEvent("\n"), encodeTextEvent("c"),
	}, "\n") + "\n"
	if output.String() != want {
		t.Fatalf("output = %q, want %q", output.String(), want)
	}
}

func TestCountdownEmitsEvents(t *testing.T) {
	output := captureEvents(t)
	if err := countdownTick(3); err != nil {
		t.Fatal(err)
	}
	if output.String() != "C3\n" {
		t.Fatalf("countdown output = %q", output.String())
	}
}

func TestInvalidTypoLibraryEmitsNoEvents(t *testing.T) {
	oldStream, oldWriter := eventStream, eventWriter
	defer func() { eventStream, eventWriter = oldStream, oldWriter }()
	eventStream = true
	var output bytes.Buffer
	eventWriter = &output
	path := filepath.Join(t.TempDir(), "typos.txt")
	for _, contents := range []string{"mot\xff=>mother", "motter=>mother=>other", "=>mother", "motter=>", "the=>the"} {
		if err := os.WriteFile(path, []byte(contents), 0600); err != nil {
			t.Fatal(err)
		}
		if err := run(options{text: "mother", typoFile: path}); err == nil {
			t.Fatalf("accepted invalid typo library: %q", contents)
		}
	}
	if output.Len() != 0 {
		t.Fatalf("typed before validating typo library: %q", output.String())
	}
}

func TestCommonPrefixRunes(t *testing.T) {
	if got := commonPrefixRunes("motter", "mother"); got != 3 {
		t.Fatalf("commonPrefixRunes() = %d, want 3", got)
	}
}

func TestEventEncoding(t *testing.T) {
	if got := encodeTextEvent("你"); got != "T5L2g" {
		t.Fatalf("encodeTextEvent() = %q", got)
	}
	if got := encodeBackspaceEvent(3); got != "B3" {
		t.Fatalf("encodeBackspaceEvent() = %q", got)
	}
}

func TestBackspaceRunesEmitsOneKeyAtATime(t *testing.T) {
	oldStream, oldWriter := eventStream, eventWriter
	defer func() {
		paused.Store(false)
		eventStream, eventWriter = oldStream, oldWriter
	}()
	eventStream = true
	output := &pauseAfterFirstWrite{first: make(chan struct{})}
	eventWriter = output
	done := make(chan error, 1)
	go func() { done <- backspaceRunes(3, 0, 0, rand.New(rand.NewSource(1))) }()
	<-output.first
	select {
	case <-done:
		t.Fatal("backspace continued after pausing mid-delete")
	case <-time.After(20 * time.Millisecond):
	}
	paused.Store(false)
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("backspace did not resume")
	}
	if got, want := output.String(), "B1\nB1\nB1\n"; got != want {
		t.Fatalf("backspace output = %q, want %q", got, want)
	}
}
