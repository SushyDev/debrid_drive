package logger

import (
	"os"
	"path/filepath"

	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
)

var LogDir = "logs"

var loggers = make(map[string]*zap.SugaredLogger)

func createLogger(fileName string) (*zap.SugaredLogger, error) {
	filePath := filepath.Join(LogDir, fileName)

	// Create the log directory if it doesn't exist
	dir := filepath.Dir(filePath)
	if err := os.MkdirAll(dir, os.ModePerm); err != nil {
		return nil, err
	}

	// Open the log file
	logFile, err := os.OpenFile(filePath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return nil, err
	}

	// Define the core for the logger
	core := zapcore.NewCore(
		zapcore.NewJSONEncoder(zap.NewProductionEncoderConfig()), // Use JSON encoding for structured logs
		zapcore.AddSync(logFile),                                 // Write logs to file
		zap.InfoLevel,                                            // Set the log level
	)

	// Return the new logger
	logger := zap.New(core, zap.AddCaller())

	return logger.Sugar(), nil
}

func GetLogger(fileName string) (*zap.SugaredLogger, error) {
	if logger, ok := loggers[fileName]; ok {
		return logger, nil
	}

	logger, err := createLogger(fileName)
	if err != nil {
		return nil, err
	}

	loggers[fileName] = logger

	return logger, nil
}
