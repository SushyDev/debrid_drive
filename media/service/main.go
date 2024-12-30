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

func (instance *MediaService) error(message string, err error) error {
	return fmt.Errorf("%s\n%w", message, err)
}
