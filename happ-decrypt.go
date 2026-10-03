package main

import (
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net/url"
	"os"
	"strings"

	"golang.org/x/crypto/chacha20poly1305"
)

func main() {
	if len(os.Args) < 2 {
		return
	}
	originalInput := os.Args[1]
	input := strings.TrimSpace(originalInput)

	// 1. Убираем префиксы протоколов
	prefixes := []string{"happ://crypt5/", "happ://crypt4/", "happ://crypt3/", "v2raytun://crypt/"}
	for _, p := range prefixes {
		if strings.HasPrefix(input, p) {
			input = strings.TrimPrefix(input, p)
			break
		}
	}

	// 2. Декодируем URL (используем PathUnescape, чтобы не ломать символ +)
	if unescaped, err := url.PathUnescape(input); err == nil {
		input = unescaped
	}

	// 3. Строго отсекаем любые параметры и алиасы
	if idx := strings.IndexAny(input, "?&#"); idx != -1 {
		input = input[:idx]
	}

	// 4. Унифицируем алфавит Base64
	input = strings.ReplaceAll(input, "-", "+")
	input = strings.ReplaceAll(input, "_", "/")

	// 5. Оставляем ТОЛЬКО чистый Base64 (без учета паддинга = и мусора)
	var clean strings.Builder
	for _, r := range input {
		if (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '+' || r == '/' {
			clean.WriteRune(r)
		}
	}

	// 6. Декодируем в "сыром" формате (Raw), которому не нужны знаки =
	data, err := base64.RawStdEncoding.DecodeString(clean.String())
	if err != nil {
		fmt.Printf("Base64 Error: %v\n", err)
		fmt.Println("Result\n" + originalInput)
		return
	}

	if len(data) < 28 {
		fmt.Printf("Data too short: %d bytes\n", len(data))
		fmt.Println("Result\n" + originalInput)
		return
	}

	nonce := data[:12]
	ciphertext := data[12:]

	keyStr := strings.Repeat("e10adc3949ba59abbe56e057f20f883e", 2)[:64]
	key, _ := hex.DecodeString(keyStr)

	aead, err := chacha20poly1305.New(key)
	if err != nil {
		fmt.Printf("Cipher Init Error: %v\n", err)
		fmt.Println("Result\n" + originalInput)
		return
	}

	decrypted, err := aead.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		fmt.Printf("Decrypt Error: %v\n", err)
		fmt.Println("Result\n" + originalInput)
		return
	}

	res := strings.TrimSpace(string(decrypted))
	if strings.HasPrefix(res, "http") || strings.Contains(res, "://") {
		fmt.Printf("Result\n%s\n", res)
	} else {
		fmt.Printf("Invalid protocol after decrypt: %s\n", res[:10])
		fmt.Println("Result\n" + originalInput)
	}
}
