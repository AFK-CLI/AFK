package auth

import (
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const testSecret = "test-secret-key-for-jwt-testing"

// =============================================================================
// IssueTokenPair tests
// =============================================================================

func TestIssueTokenPair_Success(t *testing.T) {
	userID := "user-123"
	pair, err := IssueTokenPair(userID, testSecret)
	if err != nil {
		t.Fatalf("IssueTokenPair failed: %v", err)
	}

	if pair.AccessToken == "" {
		t.Error("AccessToken should not be empty")
	}
	if pair.RefreshToken == "" {
		t.Error("RefreshToken should not be empty")
	}
	if pair.ExpiresAt == 0 {
		t.Error("ExpiresAt should not be zero")
	}

	// ExpiresAt should be ~15 minutes from now
	expectedExp := time.Now().Add(15 * time.Minute).Unix()
	if pair.ExpiresAt < expectedExp-5 || pair.ExpiresAt > expectedExp+5 {
		t.Errorf("ExpiresAt should be ~15 minutes from now, got diff of %d seconds", pair.ExpiresAt-expectedExp)
	}
}

func TestIssueTokenPair_TokensAreDifferent(t *testing.T) {
	pair, err := IssueTokenPair("user-123", testSecret)
	if err != nil {
		t.Fatalf("IssueTokenPair failed: %v", err)
	}

	if pair.AccessToken == pair.RefreshToken {
		t.Error("AccessToken and RefreshToken should be different")
	}
}

func TestIssueTokenPair_AccessTokenHasCorrectClaims(t *testing.T) {
	userID := "user-456"
	pair, err := IssueTokenPair(userID, testSecret)
	if err != nil {
		t.Fatalf("IssueTokenPair failed: %v", err)
	}

	token, err := jwt.ParseWithClaims(pair.AccessToken, &tokenClaims{}, func(token *jwt.Token) (interface{}, error) {
		return []byte(testSecret), nil
	})
	if err != nil {
		t.Fatalf("Failed to parse access token: %v", err)
	}

	claims, ok := token.Claims.(*tokenClaims)
	if !ok {
		t.Fatal("Failed to get claims from access token")
	}

	if claims.TokenType != "access" {
		t.Errorf("Expected TokenType 'access', got %q", claims.TokenType)
	}

	subject, _ := claims.GetSubject()
	if subject != userID {
		t.Errorf("Expected subject %q, got %q", userID, subject)
	}

	exp, _ := claims.GetExpirationTime()
	expectedExp := time.Now().Add(15 * time.Minute)
	if exp.Time.Before(expectedExp.Add(-10*time.Second)) || exp.Time.After(expectedExp.Add(10*time.Second)) {
		t.Errorf("Access token expiration should be ~15 minutes, got %v", exp.Time)
	}
}

func TestIssueTokenPair_RefreshTokenHasCorrectClaims(t *testing.T) {
	userID := "user-789"
	pair, err := IssueTokenPair(userID, testSecret)
	if err != nil {
		t.Fatalf("IssueTokenPair failed: %v", err)
	}

	token, err := jwt.ParseWithClaims(pair.RefreshToken, &tokenClaims{}, func(token *jwt.Token) (interface{}, error) {
		return []byte(testSecret), nil
	})
	if err != nil {
		t.Fatalf("Failed to parse refresh token: %v", err)
	}

	claims, ok := token.Claims.(*tokenClaims)
	if !ok {
		t.Fatal("Failed to get claims from refresh token")
	}

	if claims.TokenType != "refresh" {
		t.Errorf("Expected TokenType 'refresh', got %q", claims.TokenType)
	}

	subject, _ := claims.GetSubject()
	if subject != userID {
		t.Errorf("Expected subject %q, got %q", userID, subject)
	}

	exp, _ := claims.GetExpirationTime()
	expectedExp := time.Now().Add(30 * 24 * time.Hour)
	if exp.Time.Before(expectedExp.Add(-10*time.Second)) || exp.Time.After(expectedExp.Add(10*time.Second)) {
		t.Errorf("Refresh token expiration should be ~30 days, got %v", exp.Time)
	}
}

func TestIssueTokenPair_UniqueJTI(t *testing.T) {
	pair1, _ := IssueTokenPair("user-1", testSecret)
	pair2, _ := IssueTokenPair("user-1", testSecret)

	// Parse both tokens to get JTI
	getJTI := func(tokenStr string) string {
		token, _ := jwt.ParseWithClaims(tokenStr, &tokenClaims{}, func(token *jwt.Token) (interface{}, error) {
			return []byte(testSecret), nil
		})
		claims := token.Claims.(*tokenClaims)
		return claims.ID
	}

	jti1 := getJTI(pair1.AccessToken)
	jti2 := getJTI(pair2.AccessToken)

	if jti1 == jti2 {
		t.Error("Each token should have a unique JTI")
	}
}

// =============================================================================
// ValidateAccessToken tests
// =============================================================================

func TestValidateAccessToken_Success(t *testing.T) {
	userID := "user-access-123"
	pair, _ := IssueTokenPair(userID, testSecret)

	gotUserID, err := ValidateAccessToken(pair.AccessToken, testSecret)
	if err != nil {
		t.Fatalf("ValidateAccessToken failed: %v", err)
	}

	if gotUserID != userID {
		t.Errorf("Expected userID %q, got %q", userID, gotUserID)
	}
}

func TestValidateAccessToken_WrongSecret(t *testing.T) {
	pair, _ := IssueTokenPair("user-123", testSecret)

	_, err := ValidateAccessToken(pair.AccessToken, "wrong-secret")
	if err == nil {
		t.Error("ValidateAccessToken should fail with wrong secret")
	}
}

func TestValidateAccessToken_RefreshTokenRejected(t *testing.T) {
	pair, _ := IssueTokenPair("user-123", testSecret)

	_, err := ValidateAccessToken(pair.RefreshToken, testSecret)
	if err == nil {
		t.Error("ValidateAccessToken should reject refresh tokens")
	}
	if !strings.Contains(err.Error(), "not an access token") {
		t.Errorf("Expected 'not an access token' error, got: %v", err)
	}
}

func TestValidateAccessToken_ExpiredToken(t *testing.T) {
	// Create a manually expired token
	now := time.Now()
	expiredTime := now.Add(-1 * time.Hour)

	claims := tokenClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   "user-expired",
			ExpiresAt: jwt.NewNumericDate(expiredTime),
			IssuedAt:  jwt.NewNumericDate(now.Add(-2 * time.Hour)),
			ID:        GenerateID(),
		},
		TokenType: "access",
	}

	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	tokenStr, _ := token.SignedString([]byte(testSecret))

	_, err := ValidateAccessToken(tokenStr, testSecret)
	if err == nil {
		t.Error("ValidateAccessToken should reject expired tokens")
	}
}

func TestValidateAccessToken_MalformedToken(t *testing.T) {
	cases := []struct {
		name  string
		token string
	}{
		{"empty", ""},
		{"garbage", "not.a.token"},
		{"partial", "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"},
		{"invalid base64", "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.!!!.xxx"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := ValidateAccessToken(tc.token, testSecret)
			if err == nil {
				t.Errorf("ValidateAccessToken should reject malformed token: %q", tc.token)
			}
		})
	}
}

func TestValidateAccessToken_WrongSigningMethod(t *testing.T) {
	// Create a token with "none" algorithm (unsigned)
	claims := tokenClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   "user-none-alg",
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(1 * time.Hour)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
			ID:        GenerateID(),
		},
		TokenType: "access",
	}

	token := jwt.NewWithClaims(jwt.SigningMethodNone, claims)
	tokenStr, _ := token.SignedString(jwt.UnsafeAllowNoneSignatureType)

	_, err := ValidateAccessToken(tokenStr, testSecret)
	if err == nil {
		t.Error("ValidateAccessToken should reject tokens with 'none' signing method")
	}
}

// =============================================================================
// ValidateRefreshTokenJWT tests
// =============================================================================

func TestValidateRefreshTokenJWT_Success(t *testing.T) {
	userID := "user-refresh-123"
	pair, _ := IssueTokenPair(userID, testSecret)

	gotUserID, err := ValidateRefreshTokenJWT(pair.RefreshToken, testSecret)
	if err != nil {
		t.Fatalf("ValidateRefreshTokenJWT failed: %v", err)
	}

	if gotUserID != userID {
		t.Errorf("Expected userID %q, got %q", userID, gotUserID)
	}
}

func TestValidateRefreshTokenJWT_WrongSecret(t *testing.T) {
	pair, _ := IssueTokenPair("user-123", testSecret)

	_, err := ValidateRefreshTokenJWT(pair.RefreshToken, "wrong-secret")
	if err == nil {
		t.Error("ValidateRefreshTokenJWT should fail with wrong secret")
	}
}

func TestValidateRefreshTokenJWT_AccessTokenRejected(t *testing.T) {
	pair, _ := IssueTokenPair("user-123", testSecret)

	_, err := ValidateRefreshTokenJWT(pair.AccessToken, testSecret)
	if err == nil {
		t.Error("ValidateRefreshTokenJWT should reject access tokens")
	}
	if !strings.Contains(err.Error(), "not a refresh token") {
		t.Errorf("Expected 'not a refresh token' error, got: %v", err)
	}
}

func TestValidateRefreshTokenJWT_ExpiredToken(t *testing.T) {
	// Create a manually expired refresh token
	now := time.Now()
	expiredTime := now.Add(-1 * time.Hour)

	claims := tokenClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   "user-expired",
			ExpiresAt: jwt.NewNumericDate(expiredTime),
			IssuedAt:  jwt.NewNumericDate(now.Add(-2 * time.Hour)),
			ID:        GenerateID(),
		},
		TokenType: "refresh",
	}

	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	tokenStr, _ := token.SignedString([]byte(testSecret))

	_, err := ValidateRefreshTokenJWT(tokenStr, testSecret)
	if err == nil {
		t.Error("ValidateRefreshTokenJWT should reject expired tokens")
	}
}

func TestValidateRefreshTokenJWT_MalformedToken(t *testing.T) {
	cases := []struct {
		name  string
		token string
	}{
		{"empty", ""},
		{"garbage", "not.a.token"},
		{"partial", "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := ValidateRefreshTokenJWT(tc.token, testSecret)
			if err == nil {
				t.Errorf("ValidateRefreshTokenJWT should reject malformed token: %q", tc.token)
			}
		})
	}
}

// =============================================================================
// GenerateID tests
// =============================================================================

func TestGenerateID_ReturnsValidUUIDFormat(t *testing.T) {
	id := GenerateID()

	// UUID v4 format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
	// where y is 8, 9, a, or b
	if len(id) != 36 {
		t.Errorf("Expected UUID length 36, got %d: %q", len(id), id)
	}

	parts := strings.Split(id, "-")
	if len(parts) != 5 {
		t.Errorf("Expected 5 parts separated by hyphens, got %d", len(parts))
	}

	expectedLengths := []int{8, 4, 4, 4, 12}
	for i, part := range parts {
		if len(part) != expectedLengths[i] {
			t.Errorf("Part %d should have length %d, got %d", i, expectedLengths[i], len(part))
		}
	}

	// Check version 4 indicator (13th character should be '4')
	if id[14] != '4' {
		t.Errorf("UUID version should be 4, got %c at position 14", id[14])
	}

	// Check variant (17th character should be 8, 9, a, or b)
	variant := id[19]
	if variant != '8' && variant != '9' && variant != 'a' && variant != 'b' {
		t.Errorf("UUID variant should be 8, 9, a, or b, got %c at position 19", variant)
	}
}

func TestGenerateID_Uniqueness(t *testing.T) {
	ids := make(map[string]bool)
	count := 1000

	for i := 0; i < count; i++ {
		id := GenerateID()
		if ids[id] {
			t.Errorf("Duplicate ID generated: %q", id)
		}
		ids[id] = true
	}

	if len(ids) != count {
		t.Errorf("Expected %d unique IDs, got %d", count, len(ids))
	}
}

func TestGenerateID_AllHexCharacters(t *testing.T) {
	id := GenerateID()
	validChars := "0123456789abcdef-"

	for _, c := range id {
		if !strings.ContainsRune(validChars, c) {
			t.Errorf("Invalid character %q in UUID", c)
		}
	}
}
