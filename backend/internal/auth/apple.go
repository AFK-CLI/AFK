package auth

import (
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const appleKeysURL = "https://appleid.apple.com/auth/keys"
const appleIssuer = "https://appleid.apple.com"

type AppleClaims struct {
	Subject        string
	Email          string
	IsPrivateEmail bool
}

type appleJWKS struct {
	Keys []appleJWK `json:"keys"`
}

type appleJWK struct {
	KTY string `json:"kty"`
	KID string `json:"kid"`
	Use string `json:"use"`
	Alg string `json:"alg"`
	N   string `json:"n"`
	E   string `json:"e"`
}

type jwksCache struct {
	mu        sync.RWMutex
	keys      map[string]*rsa.PublicKey
	fetchedAt time.Time
}

var cache = &jwksCache{}

func fetchAppleKeys() (map[string]*rsa.PublicKey, error) {
	cache.mu.RLock()
	if time.Since(cache.fetchedAt) < time.Hour && cache.keys != nil {
		keys := cache.keys
		cache.mu.RUnlock()
		return keys, nil
	}
	cache.mu.RUnlock()

	cache.mu.Lock()
	defer cache.mu.Unlock()

	// Double-check after acquiring write lock.
	if time.Since(cache.fetchedAt) < time.Hour && cache.keys != nil {
		return cache.keys, nil
	}

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(appleKeysURL)
	if err != nil {
		return nil, fmt.Errorf("fetch apple keys: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("apple keys returned status %d", resp.StatusCode)
	}

	var jwks appleJWKS
	if err := json.NewDecoder(resp.Body).Decode(&jwks); err != nil {
		return nil, fmt.Errorf("decode apple keys: %w", err)
	}

	keys := make(map[string]*rsa.PublicKey, len(jwks.Keys))
	for _, k := range jwks.Keys {
		if k.KTY != "RSA" {
			continue
		}
		pub, err := parseRSAPublicKey(k.N, k.E)
		if err != nil {
			continue
		}
		keys[k.KID] = pub
	}

	cache.keys = keys
	cache.fetchedAt = time.Now()

	return keys, nil
}

func parseRSAPublicKey(nStr, eStr string) (*rsa.PublicKey, error) {
	nBytes, err := base64.RawURLEncoding.DecodeString(nStr)
	if err != nil {
		return nil, err
	}
	eBytes, err := base64.RawURLEncoding.DecodeString(eStr)
	if err != nil {
		return nil, err
	}

	n := new(big.Int).SetBytes(nBytes)
	e := new(big.Int).SetBytes(eBytes)

	return &rsa.PublicKey{
		N: n,
		E: int(e.Int64()),
	}, nil
}

type appleClaims struct {
	jwt.RegisteredClaims
	Email          string          `json:"email"`
	IsPrivateEmail json.RawMessage `json:"is_private_email"`
}

func (c *appleClaims) isPrivateEmail() bool {
	s := string(c.IsPrivateEmail)
	return s == "true" || s == `"true"`
}

func VerifyIdentityToken(tokenString string, bundleIDs []string) (*AppleClaims, error) {
	keys, err := fetchAppleKeys()
	if err != nil {
		return nil, fmt.Errorf("fetch keys: %w", err)
	}

	token, err := jwt.ParseWithClaims(tokenString, &appleClaims{}, func(token *jwt.Token) (interface{}, error) {
		kid, ok := token.Header["kid"].(string)
		if !ok {
			return nil, errors.New("missing kid in token header")
		}
		key, ok := keys[kid]
		if !ok {
			return nil, fmt.Errorf("unknown kid: %s", kid)
		}
		return key, nil
	},
		jwt.WithValidMethods([]string{"RS256"}),
		jwt.WithIssuer(appleIssuer),
		jwt.WithExpirationRequired(),
	)
	if err != nil {
		return nil, fmt.Errorf("validate token: %w", err)
	}

	claims, ok := token.Claims.(*appleClaims)
	if !ok || !token.Valid {
		return nil, errors.New("invalid token claims")
	}

	// Validate audience against allowed bundle IDs.
	aud, _ := claims.GetAudience()
	if !audienceMatches(aud, bundleIDs) {
		return nil, fmt.Errorf("token audience %v does not match allowed bundle IDs", aud)
	}

	subject, err := claims.GetSubject()
	if err != nil {
		return nil, fmt.Errorf("get subject: %w", err)
	}

	return &AppleClaims{
		Subject:        subject,
		Email:          claims.Email,
		IsPrivateEmail: claims.isPrivateEmail(),
	}, nil
}

func audienceMatches(aud jwt.ClaimStrings, allowed []string) bool {
	for _, a := range aud {
		for _, b := range allowed {
			if a == b {
				return true
			}
		}
	}
	return false
}
