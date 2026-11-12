package typos

import (
	"strings"
	"testing"

	"mac-typer/internal/engine"
)

type replaySink struct{ out []rune }

func (s *replaySink) Text(t string) error { s.out = append(s.out, []rune(t)...); return nil }
func (s *replaySink) Backspace() error {
	if len(s.out) > 0 {
		s.out = s.out[:len(s.out)-1]
	}
	return nil
}

func TestCommonLibrary(t *testing.T) {
	rules, err := engine.ParseTypos(strings.NewReader(Common))
	if err != nil {
		t.Fatal(err)
	}
	if len(rules) < 200 {
		t.Fatalf("built-in library has only %d rules", len(rules))
	}
	seen := map[string]bool{}
	for _, r := range rules {
		key := strings.ToLower(r.Correct)
		if seen[key] {
			t.Errorf("duplicate correct word %q", r.Correct)
		}
		seen[key] = true
	}
	input := "Because the government did not receive the address, it was definitely a surprise. 我们再接再厉，按部就班地部署。"
	typed := false
	for seed := int64(0); seed < 20; seed++ {
		sink := &replaySink{}
		var corrections int
		counting := countingSink{inner: sink, backspaces: &corrections}
		if err := engine.NewJob(engine.Config{TypoRate: 1}, rules, counting, seed).Run(input); err != nil {
			t.Fatal(err)
		}
		if string(sink.out) != input {
			t.Fatalf("seed %d: %q", seed, string(sink.out))
		}
		typed = typed || corrections > 0
	}
	if !typed {
		t.Fatal("built-in library produced no typos")
	}
}

type countingSink struct {
	inner      engine.Sink
	backspaces *int
}

func (c countingSink) Text(t string) error { return c.inner.Text(t) }
func (c countingSink) Backspace() error {
	*c.backspaces++
	return c.inner.Backspace()
}
