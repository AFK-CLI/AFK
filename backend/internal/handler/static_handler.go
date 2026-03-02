package handler

import (
	"embed"
	"io/fs"
	"net/http"
	"strings"
)

//go:embed static/privacy.html
var privacyHTML []byte

//go:embed static/terms.html
var termsHTML []byte

//go:embed static/admin
var adminFS embed.FS

func HandlePrivacy(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(privacyHTML)
}

func HandleTerms(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(termsHTML)
}

// AdminFileServer returns an http.Handler that serves the embedded React admin SPA.
// Asset requests (/admin/assets/*) get immutable cache headers.
// All other /admin/* paths serve index.html for SPA client-side routing.
func AdminFileServer() http.Handler {
	sub, _ := fs.Sub(adminFS, "static/admin")
	fileServer := http.FileServer(http.FS(sub))

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Strip /admin/ prefix for the file server.
		path := strings.TrimPrefix(r.URL.Path, "/admin/")

		// Tightened CSP: no CDN needed, Chart.js is bundled.
		w.Header().Set("Content-Security-Policy",
			"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'")

		if strings.HasPrefix(path, "assets/") {
			// Hashed asset filenames are immutable.
			w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
			http.StripPrefix("/admin/", fileServer).ServeHTTP(w, r)
			return
		}

		// SPA fallback: serve index.html for all non-asset paths.
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		data, err := fs.ReadFile(sub, "index.html")
		if err != nil {
			http.Error(w, "admin UI not available", http.StatusInternalServerError)
			return
		}
		w.Write(data)
	})
}
