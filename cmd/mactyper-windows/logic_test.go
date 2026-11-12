package main

import (
	"math"
	"strings"
	"testing"
	"time"
)

func TestStartRequestConfig(t *testing.T) {
	cfg, err := startRequest{DelayMs: 80, JitterMs: 60, Countdown: 5, TypoRate: 20, SlipRate: 5, Natural: true}.config()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Delay != 80*time.Millisecond || cfg.Jitter != 60*time.Millisecond || cfg.Countdown != 5 ||
		cfg.TypoRate != 0.2 || cfg.SlipRate != 0.05 || !cfg.Natural || !cfg.GateStart {
		t.Fatalf("config = %+v", cfg)
	}
	for _, bad := range []startRequest{
		{DelayMs: -1}, {DelayMs: 60001}, {Countdown: 1.5}, {Countdown: 3601},
		{TypoRate: 101}, {SlipRate: -1}, {DelayMs: math.NaN()}, {JitterMs: math.Inf(1)},
	} {
		if _, err := bad.config(); err == nil {
			t.Errorf("accepted %+v", bad)
		}
	}
}

func TestTypoRules(t *testing.T) {
	if rules, err := (startRequest{TypoMode: "none"}).typoRules(); err != nil || rules != nil {
		t.Fatal("none should have no rules")
	}
	rules, err := startRequest{TypoMode: "builtin"}.typoRules()
	if err != nil || len(rules) < 200 {
		t.Fatalf("builtin: %d rules, %v", len(rules), err)
	}
	rules, err = startRequest{TypoMode: "custom", TypoText: "\uFEFFteh=>the\r\n# c\r\n"}.typoRules()
	if err != nil || len(rules) != 1 || rules[0].Wrong != "teh" {
		t.Fatalf("custom: %+v, %v", rules, err)
	}
	for _, bad := range []startRequest{{TypoMode: "custom"}, {TypoMode: "custom", TypoText: "a=>b=>c"}, {TypoMode: "x"}} {
		if _, err := bad.typoRules(); err == nil {
			t.Errorf("accepted %+v", bad)
		}
	}
}

func TestValidateHotkeys(t *testing.T) {
	if err := validateHotkeys(defaultHotkeys); err != nil {
		t.Fatal(err)
	}
	dup := append([]hotkey(nil), defaultHotkeys...)
	dup[2] = dup[0]
	if err := validateHotkeys(dup); err == nil || !strings.Contains(err.Error(), "相同") {
		t.Fatalf("duplicate accepted: %v", err)
	}
	noMod := append([]hotkey(nil), defaultHotkeys...)
	noMod[1].Mods = modShift
	if validateHotkeys(noMod) == nil || validateHotkeys(defaultHotkeys[:2]) == nil {
		t.Fatal("invalid hotkeys accepted")
	}
}

func TestVersions(t *testing.T) {
	if compareVersions("v1.10.0", "1.9.2") != 1 || compareVersions("1.1", "1.1.0") != 0 || compareVersions("1.0.2", version) != -1 {
		t.Fatal("compareVersions")
	}
	latest, url, err := parseRelease([]byte(`{"tag_name":"v1.3.0","html_url":"https://github.com/Ronin-TFT/mac-typer/releases/tag/v1.3.0"}`))
	if err != nil || latest != "1.3.0" || !strings.HasSuffix(url, "v1.3.0") {
		t.Fatalf("parseRelease = %q %q %v", latest, url, err)
	}
	if _, _, err := parseRelease([]byte(`{"tag_name":"v9","html_url":"https://evil.example/"}`)); err == nil {
		t.Fatal("accepted foreign release page")
	}
}
