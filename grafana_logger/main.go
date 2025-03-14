package logging

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"go.uber.org/zap"
)

// LogLevel denotes the severity of the log.
type LogLevel string

// Log levels.
const (
	InfoLevel  LogLevel = "info"
	ErrorLevel LogLevel = "error"
)

// LokiEntry defines a single log entry for Grafana Loki.
type LokiEntry struct {
	Stream map[string]string `json:"stream"`
	Values [][2]string       `json:"values"`
}

// LokiPayload represents the payload structure for pushing batch logs to Loki.
type LokiPayload struct {
	Streams []LokiEntry `json:"streams"`
}

// GrafanaLogger provides an abstraction for logging to a Grafana Loki instance.
type GrafanaLogger struct {
	lokiURL string
	logger  *zap.Logger
}

// NewGrafanaLogger creates and returns a new instance of GrafanaLogger.
func NewGrafanaLogger(lokiURL string, logger *zap.Logger) *GrafanaLogger {
	return &GrafanaLogger{
		lokiURL: lokiURL,
		logger:  logger,
	}
}

// Log logs a message with the specified level and session ID, both locally (via zap) and remotely to Grafana Loki.
func (gl *GrafanaLogger) Log(level LogLevel, sessionID, message string, fields ...zap.Field) {
	// Create labels that can be used to filter logs in Grafana.
	labels := map[string]string{
		"session": sessionID,
		"level":   string(level),
	}

	// Log locally first.
	switch level {
	case InfoLevel:
		gl.logger.Info(message, fields...)
	case ErrorLevel:
		gl.logger.Error(message, fields...)
	}

	// Prepare the payload for Grafana Loki.
	currentTime := time.Now().UnixNano() // Timestamp in nanoseconds
	payload := LokiPayload{
		Streams: []LokiEntry{
			{
				Stream: labels,
				Values: [][2]string{
					{fmt.Sprintf("%d", currentTime), message},
				},
			},
		},
	}

	// Push log to Grafana Loki asynchronously.
	if err := gl.pushToLoki(payload); err != nil {
		gl.logger.Error("Failed to push log to Grafana Loki", zap.Error(err))
	}
}

// pushToLoki sends the log payload to the Grafana Loki instance using its push API.
func (gl *GrafanaLogger) pushToLoki(payload LokiPayload) error {
	jsonData, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("could not marshal payload: %w", err)
	}

	req, err := http.NewRequest("POST", gl.lokiURL, bytes.NewBuffer(jsonData))
	if err != nil {
		return fmt.Errorf("failed to create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("failed to send request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusOK {
		return fmt.Errorf("unexpected status code from Loki: %d", resp.StatusCode)
	}

	return nil
}
