package handler

import (
	_ "embed"
	"net/http"
)

//go:embed static/privacy.html
var privacyHTML []byte

//go:embed static/terms.html
var termsHTML []byte

func HandlePrivacy(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(privacyHTML)
}

func HandleTerms(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(termsHTML)
}
