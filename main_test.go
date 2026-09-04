package main

import (
	"bytes"
	"math/rand"
	"testing"
	"time"
)

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
