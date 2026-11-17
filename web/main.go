// Command mac-typer-web serves the Mac Typer website: a product landing page,
// an online typing practice page and a small leaderboard API.
package main

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

//go:embed templates/*.html
var templateFS embed.FS

//go:embed static
var staticFS embed.FS

// Config holds runtime settings, read from environment variables.
type Config struct {
	Addr         string
	DataDir      string
	SiteURL      string
	AppVersion   string
	DownloadURL  string
	RepoURL      string
	AdClient     string
	AdSlot       string
	TrustProxy   bool
	SubmitWindow time.Duration
}

func envOr(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func loadConfig() Config {
	return Config{
		Addr:         envOr("ADDR", ":8080"),
		DataDir:      envOr("DATA_DIR", "./data"),
		SiteURL:      strings.TrimRight(envOr("SITE_URL", "http://localhost:8080"), "/"),
		AppVersion:   envOr("APP_VERSION", "1.0.2"),
		DownloadURL:  envOr("DOWNLOAD_URL", "https://github.com/Ronin-TFT/mac-typer/releases/latest"),
		RepoURL:      envOr("REPO_URL", "https://github.com/Ronin-TFT/mac-typer"),
		AdClient:     os.Getenv("ADSENSE_CLIENT"),
		AdSlot:       os.Getenv("ADSENSE_SLOT"),
		TrustProxy:   os.Getenv("TRUST_PROXY") == "1",
		SubmitWindow: 10 * time.Second,
	}
}

// Server bundles configuration, templates and the score store.
type Server struct {
	cfg     Config
	pages   map[string]*template.Template
	scores  *ScoreStore
	limiter *RateLimiter
}

// pageData is passed to every HTML template.
type pageData struct {
	Config
	Title       string
	Description string
	Path        string
	Year        int
}

func NewServer(cfg Config) (*Server, error) {
	pages := map[string]*template.Template{}
	for _, name := range []string{"index", "typing"} {
		t, err := template.ParseFS(templateFS, "templates/layout.html", "templates/"+name+".html")
		if err != nil {
			return nil, fmt.Errorf("parse %s: %w", name, err)
		}
		pages[name] = t
	}
	if err := os.MkdirAll(cfg.DataDir, 0o755); err != nil {
		return nil, err
	}
	store, err := OpenScoreStore(filepath.Join(cfg.DataDir, "scores.json"))
	if err != nil {
		return nil, err
	}
	return &Server{cfg: cfg, pages: pages, scores: store, limiter: NewRateLimiter(cfg.SubmitWindow)}, nil
}

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	static, _ := fs.Sub(staticFS, "static")
	mux.Handle("GET /static/", http.StripPrefix("/static/", cacheFor(http.FileServerFS(static), 24*time.Hour)))

	mux.HandleFunc("GET /{$}", s.page("index", "Mac Typer — macOS 模拟键入工具",
		"Mac Typer 是一款原生 macOS 模拟键入工具，支持随机间隔、错词模拟、全局快捷键，免费下载。"))
	mux.HandleFunc("GET /typing", s.page("typing", "在线打字练习与打字速度测试 — Mac Typer",
		"免费在线打字练习：中文、英文打字速度测试，实时统计 WPM、CPM 与准确率，参与排行榜。"))

	mux.HandleFunc("GET /api/scores", s.handleListScores)
	mux.HandleFunc("POST /api/scores", s.handleSubmitScore)
	mux.HandleFunc("GET /api/version", s.handleVersion)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("GET /robots.txt", s.handleRobots)
	mux.HandleFunc("GET /sitemap.xml", s.handleSitemap)
	return securityHeaders(mux)
}

func (s *Server) page(name, title, desc string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		data := pageData{Config: s.cfg, Title: title, Description: desc, Path: r.URL.Path, Year: time.Now().Year()}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if err := s.pages[name].ExecuteTemplate(w, "layout", data); err != nil {
			log.Printf("render %s: %v", name, err)
		}
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func (s *Server) handleListScores(w http.ResponseWriter, r *http.Request) {
	mode := r.URL.Query().Get("mode")
	if !validMode(mode) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "mode 只能是 en 或 zh"})
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, s.scores.Top(mode, 20))
}

func (s *Server) handleSubmitScore(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	var sub Submission
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&sub); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "请求格式错误"})
		return
	}
	score, err := sub.Validate(time.Now())
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	if !s.limiter.Allow(s.clientIP(r), time.Now()) {
		writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "提交太频繁，请稍后再试"})
		return
	}
	rank, err := s.scores.Add(score)
	if err != nil {
		log.Printf("save score: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "保存失败"})
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"rank": rank, "score": score})
}

func (s *Server) handleVersion(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Cache-Control", "public, max-age=300")
	writeJSON(w, http.StatusOK, map[string]string{"version": s.cfg.AppVersion, "downloadUrl": s.cfg.DownloadURL})
}

func (s *Server) handleRobots(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprintf(w, "User-agent: *\nAllow: /\nDisallow: /api/\nSitemap: %s/sitemap.xml\n", s.cfg.SiteURL)
}

func (s *Server) handleSitemap(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/xml; charset=utf-8")
	fmt.Fprintf(w, `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>%[1]s/</loc><changefreq>weekly</changefreq><priority>1.0</priority></url>
  <url><loc>%[1]s/typing</loc><changefreq>daily</changefreq><priority>0.9</priority></url>
</urlset>
`, template.HTMLEscapeString(s.cfg.SiteURL))
}

// clientIP returns the caller's address. Behind a trusted reverse proxy
// (Caddy/Nginx) the last X-Forwarded-For entry is the one the proxy added.
func (s *Server) clientIP(r *http.Request) string {
	if s.cfg.TrustProxy {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			return strings.TrimSpace(parts[len(parts)-1])
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "strict-origin-when-cross-origin")
		next.ServeHTTP(w, r)
	})
}

func cacheFor(next http.Handler, d time.Duration) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", fmt.Sprintf("public, max-age=%d", int(d.Seconds())))
		next.ServeHTTP(w, r)
	})
}

func main() {
	cfg := loadConfig()
	srv, err := NewServer(cfg)
	if err != nil {
		log.Fatal(err)
	}
	httpSrv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           srv.Routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	go func() {
		log.Printf("listening on %s (site %s)", cfg.Addr, cfg.SiteURL)
		if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	httpSrv.Shutdown(ctx)
}
