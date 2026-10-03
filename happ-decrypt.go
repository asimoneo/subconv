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
	input := os.Args[1]

	prefixes := []string{"happ://crypt5/", "happ://crypt4/", "happ://crypt3/", "v2raytun://crypt/"}
	for _, p := range prefixes {
		if strings.HasPrefix(input, p) {
			input = strings.TrimPrefix(input, p)
			break
		}
	}
	input, _ = url.QueryUnescape(input)

	if pad := len(input) % 4; pad != 0 {
		input += strings.Repeat("=", 4-pad)
	}

	data, err := base64.StdEncoding.DecodeString(input)
	if err != nil {
		fmt.Println("Result\n" + os.Args[1])
		return
	}

	if len(data) < 28 {
		fmt.Println("Result\n" + os.Args[1])
		return
	}

	nonce := data[:12]
	ciphertext := data[12:]

	keyStr := strings.Repeat("e10adc3949ba59abbe56e057f20f883e", 2)[:64]
	key, _ := hex.DecodeString(keyStr)

	aead, err := chacha20poly1305.New(key)
	if err != nil {
		fmt.Println("Result\n" + os.Args[1])
		return
	}

	decrypted, err := aead.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		fmt.Printf("Decrypt Error: %v\n", err)
		fmt.Println("Result\n" + os.Args[1])
		return
	}

	res := string(decrypted)
	if strings.Contains(res, "http") {
		fmt.Printf("Result\n%s\n", strings.TrimSpace(res))
	} else {
		fmt.Println("Result\n" + os.Args[1])
	}
}
