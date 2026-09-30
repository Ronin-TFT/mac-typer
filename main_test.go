package main

import (
	"bytes"
	"math/rand"
	"os"
	"path/filepath"
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

func TestNextTypo(t *testing.T) {
	got, ok := nextTypo("the address", []typo{
		{wrong: "teh", correct: "the"},
		{wrong: "adress", correct: "address"},
	})
	if !ok || got.wrong != "teh" || got.correct != "the" {
		t.Fatalf("nextTypo() = %+v, %v", got, ok)
	}
}

func TestInvalidTypoLibraryEmitsNoEvents(t *testing.T) {
	oldStream, oldWriter := eventStream, eventWriter
	defer func() { eventStream, eventWriter = oldStream, oldWriter }()
	eventStream = true
	var output bytes.Buffer
	eventWriter = &output
	path := filepath.Join(t.TempDir(), "typos.txt")
	for _, contents := range []string{"mot\xff=>mother", "motter=>mother=>other", "=>mother", "motter=>"} {
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
