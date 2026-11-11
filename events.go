package main

import (
	"encoding/base64"
	"fmt"
	"io"
	"os"
)

var eventWriter io.Writer = os.Stdout

func keystroke(s string) error {
	if eventStream {
		_, err := fmt.Fprintln(eventWriter, encodeTextEvent(s))
		return err
	}
	return postNativeText(s)
}

func sendBackspace(n int) error {
	if eventStream {
		_, err := fmt.Fprintln(eventWriter, encodeBackspaceEvent(n))
		return err
	}
	for i := 0; i < n; i++ {
		if err := postNativeBackspace(); err != nil {
			return err
		}
	}
	return nil
}

func countdownTick(seconds int) error {
	if eventStream {
		_, err := fmt.Fprintln(eventWriter, encodeCountdownEvent(seconds))
		return err
	}
	_, err := fmt.Printf("%d...\n", seconds)
	return err
}

func encodeTextEvent(s string) string {
	return "T" + base64.StdEncoding.EncodeToString([]byte(s))
}

func encodeBackspaceEvent(n int) string {
	return fmt.Sprintf("B%d", n)
}

func encodeCountdownEvent(seconds int) string {
	return fmt.Sprintf("C%d", seconds)
}
