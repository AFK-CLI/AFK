package auth

import (
	"github.com/go-webauthn/webauthn/webauthn"
)

// NewWebAuthn creates a configured WebAuthn instance.
func NewWebAuthn(rpID, rpOrigin, rpName string) (*webauthn.WebAuthn, error) {
	cfg := &webauthn.Config{
		RPID:          rpID,
		RPDisplayName: rpName,
		RPOrigins:     []string{rpOrigin},
	}
	return webauthn.New(cfg)
}
