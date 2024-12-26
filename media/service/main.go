package service

import (
	"database/sql"
	"fmt"
	"sync"
)

type MediaService struct {
	database *sql.DB
	mutex    *sync.Mutex
}

func NewMediaService(database *sql.DB) *MediaService {
	return &MediaService{
		database: database,
	}
}

func serviceError(message string, err error) error {
	if err == nil {
		return nil
	}

	return fmt.Errorf("%s\n%w", message, err)
}
