package main

import (
	"encoding/json"
	"errors"
	"math"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

const keepPerMode = 100

// Submission is what the browser sends after a finished test.
type Submission struct {
	Name     string  `json:"name"`
	Mode     string  `json:"mode"`
	Correct  int     `json:"correct"`  // correctly typed characters
	Typed    int     `json:"typed"`    // all typed characters
	Duration float64 `json:"duration"` // seconds
}

// Score is a stored leaderboard entry. Speed is WPM for "en", CPM for "zh",
// always computed on the server from the submitted counts.
type Score struct {
	Name     string    `json:"name"`
	Mode     string    `json:"mode"`
	Speed    float64   `json:"speed"`
	Accuracy float64   `json:"accuracy"`
	Duration float64   `json:"duration"`
	At       time.Time `json:"at"`
}

func validMode(m string) bool { return m == "en" || m == "zh" }

// Speed limits well above human records; anything faster is rejected.
var maxSpeed = map[string]float64{"en": 250, "zh": 400}

func (s Submission) Validate(now time.Time) (Score, error) {
	name := strings.TrimSpace(s.Name)
	n := utf8.RuneCountInString(name)
	if !utf8.ValidString(name) || n < 1 || n > 16 {
		return Score{}, errors.New("昵称需为 1–16 个字符")
	}
	for _, r := range name {
		if unicode.IsControl(r) || r == '<' || r == '>' {
			return Score{}, errors.New("昵称包含不允许的字符")
		}
	}
	if !validMode(s.Mode) {
		return Score{}, errors.New("mode 只能是 en 或 zh")
	}
	if math.IsNaN(s.Duration) || s.Duration < 10 || s.Duration > 600 {
		return Score{}, errors.New("测试时长需在 10–600 秒之间")
	}
	if s.Correct < 10 || s.Typed < s.Correct || s.Typed > 20000 {
		return Score{}, errors.New("字数不合法")
	}
	minutes := s.Duration / 60
	speed := float64(s.Correct) / minutes
	if s.Mode == "en" {
		speed /= 5 // standard WPM: 5 characters per word
	}
	if speed > maxSpeed[s.Mode] {
		return Score{}, errors.New("速度超出合理范围")
	}
	return Score{
		Name:     name,
		Mode:     s.Mode,
		Speed:    round1(speed),
		Accuracy: round1(float64(s.Correct) / float64(s.Typed) * 100),
		Duration: round1(s.Duration),
		At:       now.UTC().Truncate(time.Second),
	}, nil
}

func round1(f float64) float64 { return math.Round(f*10) / 10 }

// ScoreStore keeps the top scores per mode in memory and in a JSON file.
type ScoreStore struct {
	mu     sync.RWMutex
	path   string
	scores map[string][]Score
}

func OpenScoreStore(path string) (*ScoreStore, error) {
	st := &ScoreStore{path: path, scores: map[string][]Score{}}
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return st, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(b, &st.scores); err != nil {
		return nil, err
	}
	return st, nil
}

func better(a, b Score) bool {
	if a.Speed != b.Speed {
		return a.Speed > b.Speed
	}
	if a.Accuracy != b.Accuracy {
		return a.Accuracy > b.Accuracy
	}
	return a.At.Before(b.At)
}

// Add inserts a score and returns its 1-based rank, or 0 if it did not make
// the stored list.
func (st *ScoreStore) Add(sc Score) (int, error) {
	st.mu.Lock()
	defer st.mu.Unlock()
	list := append(st.scores[sc.Mode], sc)
	sort.SliceStable(list, func(i, j int) bool { return better(list[i], list[j]) })
	if len(list) > keepPerMode {
		list = list[:keepPerMode]
	}
	rank := 0
	for i := range list {
		if list[i] == sc {
			rank = i + 1
			break
		}
	}
	prev := st.scores[sc.Mode]
	st.scores[sc.Mode] = list
	if err := st.saveLocked(); err != nil {
		st.scores[sc.Mode] = prev
		return 0, err
	}
	return rank, nil
}

func (st *ScoreStore) Top(mode string, n int) []Score {
	st.mu.RLock()
	defer st.mu.RUnlock()
	list := st.scores[mode]
	if len(list) > n {
		list = list[:n]
	}
	out := make([]Score, len(list))
	copy(out, list)
	return out
}

// saveLocked writes atomically: temp file then rename.
func (st *ScoreStore) saveLocked() error {
	b, err := json.Marshal(st.scores)
	if err != nil {
		return err
	}
	tmp := st.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, st.path)
}

// RateLimiter allows one action per key per window.
type RateLimiter struct {
	mu     sync.Mutex
	window time.Duration
	last   map[string]time.Time
}

func NewRateLimiter(window time.Duration) *RateLimiter {
	return &RateLimiter{window: window, last: map[string]time.Time{}}
}

func (l *RateLimiter) Allow(key string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.last) > 10000 { // drop expired entries so the map stays small
		for k, t := range l.last {
			if now.Sub(t) >= l.window {
				delete(l.last, k)
			}
		}
	}
	if t, ok := l.last[key]; ok && now.Sub(t) < l.window {
		return false
	}
	l.last[key] = now
	return true
}
