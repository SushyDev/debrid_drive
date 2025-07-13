package database

import (
	"database/sql"
	"fmt"

	_ "modernc.org/sqlite"
)

type Instance struct {
	db *sql.DB
}

func NewInstance() (*Instance, error) {
	db, err := initializeDatabase()
	if err != nil {
		return nil, err
	}

	if db == nil {
		return nil, fmt.Errorf("database is nil")
	}

	instance := &Instance{
		db: db,
	}

	return instance, nil
}

func initializeDatabase() (*sql.DB, error) {
	db, err := sql.Open("sqlite", "app_data/media.db")
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %v", err)
	}

	err = enableWAL(db)
	if err != nil {
		return nil, fmt.Errorf("failed to enable WAL: %v", err)
	}

	err = createTorrentsTable(db)
	if err != nil {
		return nil, fmt.Errorf("failed to create torrents table: %v", err)
	}

	err = createIndecesOnTorrentsTable(db)
	if err != nil {
		return nil, fmt.Errorf("failed to create indeces on torrents table: %v", err)
	}

	err = createTorrentFilesTable(db)
	if err != nil {
		return nil, fmt.Errorf("failed to create table: %v", err)
	}

	err = createRejectedTorrentsTable(db)
	if err != nil {
		return nil, fmt.Errorf("failed to create table: %v", err)
	}

	return db, nil
}

func (instance *Instance) Close() {
	instance.db.Close()
}

func (instance *Instance) NewTransaction() (*sql.Tx, error) {
	return instance.db.Begin()
}

func (instance *Instance) GetDatabase() *sql.DB {
	return instance.db
}
