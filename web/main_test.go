package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func newTestServer(t *testing.T) (*Server, http.Handler) {
	t.Helper()
	cfg := loadConfig()
	cfg.DataDir = t.TempDir()
	cfg.SiteURL = "https://example.test"
	srv, err := NewServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return srv, srv.Routes()
}

func do(h http.Handler, method, path, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.RemoteAddr = "203.0.113.1:1234"
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestPages(t *testing.T) {
	_, h := newTestServer(t)
	for path, want := range map[string]string{
		"/":                 "免费下载",
		"/typing":           "在线打字练习",
		"/static/typing.js": "PASSAGES",
		"/static/style.css": "--accent",
		"/robots.txt":       "https://example.test/sitemap.xml",
		"/sitemap.xml":      "https://example.test/typing",
		"/api/version":      "downloadUrl",
		"/healthz":          "ok",
	} {
		rec := do(h, "GET", path, "")
		if rec.Code != 200 || !strings.Contains(rec.Body.String(), want) {
			t.Errorf("GET %s: code %d, missing %q", path, rec.Code, want)
		}
	}
	if rec := do(h, "GET", "/nope", ""); rec.Code != 404 {
		t.Errorf("unknown path: got %d", rec.Code)
	}
}

func TestAdsOnlyWhenConfigured(t *testing.T) {
	_, h := newTestServer(t)
	if strings.Contains(do(h, "GET", "/", "").Body.String(), "adsbygoogle") {
		t.Error("ads rendered without ADSENSE_CLIENT")
	}
	cfg := loadConfig()
	cfg.DataDir = t.TempDir()
	cfg.AdClient, cfg.AdSlot = "ca-pub-123", "456"
	srv, err := NewServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(do(srv.Routes(), "GET", "/", "").Body.String(), `data-ad-slot="456"`) {
		t.Error("ad slot missing when configured")
	}
}

func TestValidate(t *testing.T) {
	now := time.Now()
	good := Submission{Name: "小明", Mode: "zh", Correct: 60, Typed: 64, Duration: 60}
	sc, err := good.Validate(now)
	if err != nil {
		t.Fatal(err)
	}
	if sc.Speed != 60 || sc.Accuracy != 93.8 {
		t.Errorf("got speed %v acc %v", sc.Speed, sc.Accuracy)
	}
	en := Submission{Name: "bob", Mode: "en", Correct: 300, Typed: 300, Duration: 60}
	if sc, _ := en.Validate(now); sc.Speed != 60 {
		t.Errorf("en wpm: got %v", sc.Speed)
	}
	bad := []Submission{
		{Name: "", Mode: "zh", Correct: 60, Typed: 60, Duration: 60},
		{Name: "这是一个超过十六个字符长度的昵称啊啊", Mode: "zh", Correct: 60, Typed: 60, Duration: 60},
		{Name: "<b>", Mode: "zh", Correct: 60, Typed: 60, Duration: 60},
		{Name: "a", Mode: "jp", Correct: 60, Typed: 60, Duration: 60},
		{Name: "a", Mode: "zh", Correct: 60, Typed: 60, Duration: 5},
		{Name: "a", Mode: "zh", Correct: 60, Typed: 50, Duration: 60},
		{Name: "a", Mode: "zh", Correct: 1000, Typed: 1000, Duration: 60},
		{Name: "a", Mode: "en", Correct: 2000, Typed: 2000, Duration: 60},
	}
	for i, b := range bad {
		if _, err := b.Validate(now); err == nil {
			t.Errorf("case %d accepted: %+v", i, b)
		}
	}
}

func TestSubmitAndLeaderboard(t *testing.T) {
	srv, h := newTestServer(t)
	rec := do(h, "POST", "/api/scores", `{"name":"alice","mode":"en","correct":250,"typed":260,"duration":60}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("submit: %d %s", rec.Code, rec.Body)
	}
	// Same IP again within the window is limited.
	if rec := do(h, "POST", "/api/scores", `{"name":"alice","mode":"en","correct":250,"typed":260,"duration":60}`); rec.Code != http.StatusTooManyRequests {
		t.Errorf("rate limit: got %d", rec.Code)
	}
	if rec := do(h, "POST", "/api/scores", `{"name":"x","mode":"en","extra":1}`); rec.Code != http.StatusBadRequest {
		t.Errorf("unknown field: got %d", rec.Code)
	}
	if rec := do(h, "GET", "/api/scores?mode=xx", ""); rec.Code != http.StatusBadRequest {
		t.Errorf("bad mode: got %d", rec.Code)
	}
	var list []Score
	json.Unmarshal(do(h, "GET", "/api/scores?mode=en", "").Body.Bytes(), &list)
	if len(list) != 1 || list[0].Name != "alice" || list[0].Speed != 50 {
		t.Fatalf("leaderboard: %+v", list)
	}
	// Scores survive a restart.
	reopened, err := OpenScoreStore(srv.scores.path)
	if err != nil || len(reopened.Top("en", 10)) != 1 {
		t.Fatalf("reload: %v %+v", err, reopened.Top("en", 10))
	}
}

func TestStoreRankingAndCap(t *testing.T) {
	st, err := OpenScoreStore(t.TempDir() + "/s.json")
	if err != nil {
		t.Fatal(err)
	}
	base := time.Unix(1700000000, 0)
	for i := 0; i < keepPerMode+5; i++ {
		st.Add(Score{Name: "u", Mode: "zh", Speed: float64(i), Accuracy: 90, At: base.Add(time.Duration(i) * time.Second)})
	}
	top := st.Top("zh", 1000)
	if len(top) != keepPerMode || top[0].Speed != keepPerMode+4 {
		t.Fatalf("len %d first %v", len(top), top[0].Speed)
	}
	if rank, _ := st.Add(Score{Name: "slow", Mode: "zh", Speed: 0, At: base}); rank != 0 {
		t.Errorf("too slow score got rank %d", rank)
	}
}

func TestRateLimiter(t *testing.T) {
	l := NewRateLimiter(10 * time.Second)
	now := time.Now()
	if !l.Allow("a", now) || l.Allow("a", now.Add(5*time.Second)) || !l.Allow("b", now) || !l.Allow("a", now.Add(11*time.Second)) {
		t.Error("unexpected limiter behaviour")
	}
}

func TestClientIPBehindProxy(t *testing.T) {
	srv, _ := newTestServer(t)
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "172.18.0.2:5555"
	req.Header.Set("X-Forwarded-For", "1.1.1.1, 198.51.100.7")
	if ip := srv.clientIP(req); ip != "172.18.0.2" {
		t.Errorf("untrusted proxy: got %s", ip)
	}
	srv.cfg.TrustProxy = true
	if ip := srv.clientIP(req); ip != "198.51.100.7" {
		t.Errorf("trusted proxy: got %s", ip)
	}
}
