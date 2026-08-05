// SUT V1 Bendimu — extension du simulated_tls_server Bremler avec 3 handlers PSD2
// synthétiques conformes Berlin Group NextGenPSD2. Délais fixes, stdlib only.
package main

import (
	"crypto/rand"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"
)

const (
	delayAisp      = 100 * time.Millisecond
	delayAuthorize = 200 * time.Millisecond
	delayExecute   = 400 * time.Millisecond
)

var (
	payload10KB = mustRand(10 * 1024)
	payload1MB  = mustRand(1024 * 1024)
)

func mustRand(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		log.Fatalf("rand: %v", err)
	}
	return b
}

// --- Endpoints hérités Bremler (compatibilité V0) ---
func handleRoot(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte("<html><body>bendimu sut-v1 ok</body></html>"))
}

func handleData10KB(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/octet-stream")
	_, _ = w.Write(payload10KB)
}

func handleData1MB(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/octet-stream")
	_, _ = w.Write(payload1MB)
}

// --- Handlers PSD2 synthétiques Berlin Group ---
func handleAispAccounts(w http.ResponseWriter, _ *http.Request) {
	time.Sleep(delayAisp)
	resp := map[string]any{
		"accounts": []map[string]any{
			{"resourceId": "3dc3d5b3-7023-4848-9853-f5400a64e80f", "iban": "DE2310010010123456789", "currency": "EUR"},
			{"resourceId": "d3c94e5b-4a2b-4b6d-8f8e-1e2f3d4c5b6a", "iban": "DE2310010010987654321", "currency": "EUR"},
		},
	}
	writeJSON(w, http.StatusOK, resp)
}

func handleAuthorize(w http.ResponseWriter, _ *http.Request) {
	time.Sleep(delayAuthorize)
	resp := map[string]any{
		"authorisationId": "a1b2c3d4-e5f6-7890-1234-567890abcdef",
		"scaStatus":       "received",
		"_links": map[string]any{
			"scaStatus": map[string]string{"href": "/v1/payments/sepa-credit-transfers/authorisations/a1b2c3d4"},
		},
	}
	writeJSON(w, http.StatusCreated, resp)
}

func handleExecute(w http.ResponseWriter, _ *http.Request) {
	time.Sleep(delayExecute)
	resp := map[string]any{
		"transactionStatus": "ACCP",
		"paymentId":         "p1q2r3s4-t5u6-7890-1234-567890abcdef",
		"transactionFees":   map[string]string{"amount": "0.35", "currency": "EUR"},
		"scaMethods":        []string{"SMS_OTP", "CHIP_OTP"},
		"chosenScaMethod":   "SMS_OTP",
	}
	writeJSON(w, http.StatusOK, resp)
}

// --- Healthcheck (hors mesures) ---
func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func main() {
	mux := http.NewServeMux()

	// Bremler-compatibles
	mux.HandleFunc("/", handleRoot)
	mux.HandleFunc("/data10kb", handleData10KB)
	mux.HandleFunc("/data1mb", handleData1MB)

	// PSD2 Berlin Group
	mux.HandleFunc("/aisp/accounts", handleAispAccounts)
	mux.HandleFunc("/pisp/authorize", handleAuthorize)
	mux.HandleFunc("/pisp/execute", handleExecute)

	// Healthcheck
	mux.HandleFunc("/healthz", handleHealthz)

	addr := ":8080"
	if v := os.Getenv("SUT_ADDR"); v != "" {
		addr = v
	}

	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	log.Printf("sut-v1 listening on %s", addr)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("server: %v", err)
	}
}
