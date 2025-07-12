package repository

import (
	"database/sql"
	"fmt"
)

type MediaRepository struct {
	database *sql.DB
}

func NewMediaService(database *sql.DB) *MediaRepository {
	return &MediaRepository{
		database: database,
	}
}

func (instance *MediaRepository) error(message string, err error) error {
	return fmt.Errorf("%s\n%w", message, err)
}
