package main

import (
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"mac-typer/internal/engine"
)

type recordSink struct {
	mu   sync.Mutex
	keys []string
}

func (s *recordSink) Text(t string) error { return s.add(t) }
func (s *recordSink) Backspace() error    { return s.add("⌫") }
func (s *recordSink) add(k string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.keys = append(s.keys, k)
	return nil
}
func (s *recordSink) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return strings.Join(s.keys, "")
}

func TestInvalidInputEmitsNoEvents(t *testing.T) {
	sink := &recordSink{}
	for _, opts := range []options{
		{text: "hello", cfg: engine.Config{Delay: -1}},
		{text: "hello", cfg: engine.Config{Jitter: 61 * time.Second}},
		{text: "hello", cfg: engine.Config{Countdown: -1}},
		{text: "hello", cfg: engine.Config{Countdown: 3601}},
		{text: "hello", cfg: engine.Config{TypoRate: -0.1}},
		{text: "hello", cfg: engine.Config{TypoRate: 1.5}},
		{text: "hello", cfg: engine.Config{TypoRate: math.NaN()}},
		{text: "hello", cfg: engine.Config{SlipRate: 2}},
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

func TestRunReadsStdin(t *testing.T) {
	sink := &recordSink{}
	if err := run(options{stdin: strings.NewReader("hi")}, sink); err != nil {
		t.Fatal(err)
	}
	if sink.String() != "hi" {
		t.Fatalf("output = %q", sink)
	}
}
