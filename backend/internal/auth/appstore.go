package auth

import (
	"crypto/ecdsa"
	"crypto/x509"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// Apple Root CA - G3, embedded from certs/AppleRootCA-G3.pem.
// Downloaded from https://www.apple.com/certificateauthority/
//
//go:embed certs/AppleRootCA-G3.pem
var appleRootCAPEM []byte

// appleRootPool is parsed once at init to avoid per-request PEM decoding.
var appleRootPool *x509.CertPool

func init() {
	block, _ := pem.Decode(appleRootCAPEM)
	if block == nil {
		panic("auth: failed to decode embedded Apple Root CA PEM")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		panic("auth: failed to parse embedded Apple Root CA: " + err.Error())
	}
	appleRootPool = x509.NewCertPool()
	appleRootPool.AddCert(cert)
}

// NotificationPayload represents the decoded App Store Server Notification V2.
type NotificationPayload struct {
	NotificationType string           `json:"notificationType"`
	Subtype          string           `json:"subtype"`
	Data             NotificationData `json:"data"`
}

type NotificationData struct {
	SignedTransactionInfo string `json:"signedTransactionInfo"`
	SignedRenewalInfo     string `json:"signedRenewalInfo"`
}

// TransactionInfo represents decoded transaction information from Apple.
type TransactionInfo struct {
	OriginalTransactionId string `json:"originalTransactionId"`
	TransactionId         string `json:"transactionId"`
	ProductId             string `json:"productId"`
	BundleId              string `json:"bundleId"`
	ExpiresDate           int64  `json:"expiresDate"` // milliseconds since epoch
	PurchaseDate          int64  `json:"purchaseDate"`
	Type                  string `json:"type"`
}

// ExpiresTime converts the millisecond timestamp to time.Time.
func (t *TransactionInfo) ExpiresTime() *time.Time {
	if t.ExpiresDate == 0 {
		return nil
	}
	ts := time.UnixMilli(t.ExpiresDate)
	return &ts
}

// VerifyAppStoreJWS verifies an App Store Server Notification V2 signed payload.
func VerifyAppStoreJWS(signedPayload string) (*NotificationPayload, error) {
	claims, err := verifyAppleJWS(signedPayload)
	if err != nil {
		return nil, fmt.Errorf("verify notification JWS: %w", err)
	}

	var payload NotificationPayload
	claimsBytes, err := json.Marshal(claims)
	if err != nil {
		return nil, fmt.Errorf("marshal claims: %w", err)
	}
	if err := json.Unmarshal(claimsBytes, &payload); err != nil {
		return nil, fmt.Errorf("unmarshal notification payload: %w", err)
	}
	return &payload, nil
}

// VerifySignedTransaction verifies and decodes a signed transaction from Apple.
func VerifySignedTransaction(signedTransaction string) (*TransactionInfo, error) {
	claims, err := verifyAppleJWS(signedTransaction)
	if err != nil {
		return nil, fmt.Errorf("verify transaction JWS: %w", err)
	}

	var txInfo TransactionInfo
	claimsBytes, err := json.Marshal(claims)
	if err != nil {
		return nil, fmt.Errorf("marshal claims: %w", err)
	}
	if err := json.Unmarshal(claimsBytes, &txInfo); err != nil {
		return nil, fmt.Errorf("unmarshal transaction info: %w", err)
	}
	return &txInfo, nil
}

// verifyAppleJWS performs JWS verification against Apple's certificate chain.
func verifyAppleJWS(tokenString string) (jwt.MapClaims, error) {
	// Parse without verification first to get the header.
	parser := jwt.NewParser()
	token, parts, err := parser.ParseUnverified(tokenString, jwt.MapClaims{})
	if err != nil {
		return nil, fmt.Errorf("parse JWS: %w", err)
	}
	_ = parts

	// Extract x5c from header.
	x5c, ok := token.Header["x5c"].([]interface{})
	if !ok || len(x5c) == 0 {
		return nil, fmt.Errorf("missing x5c in JWS header")
	}

	// Decode certificate chain.
	certs := make([]*x509.Certificate, len(x5c))
	for i, certB64 := range x5c {
		certStr, ok := certB64.(string)
		if !ok {
			return nil, fmt.Errorf("x5c[%d] is not a string", i)
		}
		certDER, err := base64.StdEncoding.DecodeString(certStr)
		if err != nil {
			return nil, fmt.Errorf("decode x5c[%d]: %w", i, err)
		}
		cert, err := x509.ParseCertificate(certDER)
		if err != nil {
			return nil, fmt.Errorf("parse x5c[%d]: %w", i, err)
		}
		certs[i] = cert
	}

	// Build intermediate pool from the chain (excluding the leaf).
	intermediatePool := x509.NewCertPool()
	for _, cert := range certs[1:] {
		intermediatePool.AddCert(cert)
	}

	// Verify the leaf certificate chain against the embedded Apple Root CA.
	leaf := certs[0]
	opts := x509.VerifyOptions{
		Roots:         appleRootPool,
		Intermediates: intermediatePool,
	}
	if _, err := leaf.Verify(opts); err != nil {
		return nil, fmt.Errorf("verify certificate chain: %w", err)
	}

	// Verify JWS signature with leaf cert's public key.
	ecdsaKey, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok {
		return nil, fmt.Errorf("leaf certificate key is not ECDSA")
	}

	// Re-parse with verification using the leaf's public key.
	verifiedToken, err := jwt.Parse(tokenString, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodECDSA); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
		}
		return ecdsaKey, nil
	})
	if err != nil {
		return nil, fmt.Errorf("verify JWS signature: %w", err)
	}

	claims, ok := verifiedToken.Claims.(jwt.MapClaims)
	if !ok {
		return nil, fmt.Errorf("invalid claims type")
	}

	return claims, nil
}
