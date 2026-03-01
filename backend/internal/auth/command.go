package auth

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

type SignedCommand struct {
	CommandID  string `json:"commandId"`
	SessionID  string `json:"sessionId"`
	PromptHash string `json:"promptHash"`
	Nonce      string `json:"nonce"`
	ExpiresAt  int64  `json:"expiresAt"`
	Signature  string `json:"signature"`
}

// GenerateServerKeyPair generates a new Ed25519 key pair for the server
func GenerateServerKeyPair() (ed25519.PublicKey, ed25519.PrivateKey, error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, nil, fmt.Errorf("generate ed25519 key pair: %w", err)
	}
	return pub, priv, nil
}

// HashPrompt returns the SHA-256 hex digest of a prompt string
func HashPrompt(prompt string) string {
	h := sha256.Sum256([]byte(prompt))
	return hex.EncodeToString(h[:])
}

// SignCommand signs the command's canonical string using the server's private key.
// Canonical string: "commandId|sessionId|promptHash|nonce|expiresAt"
func SignCommand(cmd *SignedCommand, privateKey ed25519.PrivateKey) {
	canonical := canonicalString(cmd)
	sig := ed25519.Sign(privateKey, []byte(canonical))
	cmd.Signature = hex.EncodeToString(sig)
}

// VerifyCommandSignature verifies the Ed25519 signature on a signed command
func VerifyCommandSignature(cmd *SignedCommand, publicKey ed25519.PublicKey) error {
	if cmd.Signature == "" {
		return errors.New("missing signature")
	}
	sig, err := hex.DecodeString(cmd.Signature)
	if err != nil {
		return fmt.Errorf("invalid signature encoding: %w", err)
	}
	canonical := canonicalString(cmd)
	if !ed25519.Verify(publicKey, []byte(canonical), sig) {
		return errors.New("invalid signature")
	}
	if time.Now().Unix() > cmd.ExpiresAt {
		return errors.New("command expired")
	}
	return nil
}

func canonicalString(cmd *SignedCommand) string {
	return strings.Join([]string{
		cmd.CommandID,
		cmd.SessionID,
		cmd.PromptHash,
		cmd.Nonce,
		strconv.FormatInt(cmd.ExpiresAt, 10),
	}, "|")
}
