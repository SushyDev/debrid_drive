package repository

import (
	"database/sql"
	"fmt"
	"sync"
)

type MediaRepository struct {
	database *sql.DB
	mutex    *sync.Mutex
}

func NewMediaService(database *sql.DB) *MediaRepository {
	return &MediaRepository{
		database: database,
	}
}

func (instance *MediaRepository) error(message string, err error) error {
	return fmt.Errorf("%s\n%w", message, err)
}
