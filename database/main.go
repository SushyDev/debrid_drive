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

	return &Instance{
		db: db,
	}, nil
}

func initializeDatabase() (*sql.DB, error) {
	db, err := sql.Open("sqlite", "app_data/media.db")
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %v", err)
	}

	if err := enableWAL(db); err != nil {
		return nil, fmt.Errorf("Failed to enable WAL: %v", err)
	}

	// Check current journal mode
	var journalMode string
	err = db.QueryRow("PRAGMA journal_mode").Scan(&journalMode)
	if err != nil {
		return nil, fmt.Errorf("failed to check journal mode: %v", err)
	}
	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS torrents (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			torrent_id TEXT NOT NULL,
			name TEXT NOT NULL,

			UNIQUE(torrent_id)
		);
	`)

	if err != nil {
		return nil, fmt.Errorf("failed to create table: %v", err)
	}

	_, err = db.Exec(`
		CREATE INDEX IF NOT EXISTS idx_torrents_torrent_id 
		ON torrents (torrent_id);
	`)

	if err != nil {
		return nil, fmt.Errorf("failed to create index: %v", err)
	}

	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS torrent_files (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			torrent_id INTEGER NOT NULL,
			path TEXT NOT NULL,
			size INTEGER NOT NULL,
			link INTEGER NOT NULL,
			file_index INTEGER NOT NULL,
			file_node_id INTEGER NOT NULL,

			UNIQUE(torrent_id, file_index),
			UNIQUE(file_node_id),

			FOREIGN KEY(torrent_id) REFERENCES torrents(id)
		);
	`)

	if err != nil {
		return nil, fmt.Errorf("failed to create table: %v", err)
	}

	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS rejected_torrents (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			torrent_id TEXT NOT NULL,
			name TEXT NOT NULL,
				
			UNIQUE(torrent_id)
		);
	`)

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

func enableWAL(db *sql.DB) error {
	_, err := db.Exec("PRAGMA journal_mode=WAL")
	if err != nil {
		return fmt.Errorf("failed to enable WAL mode: %v", err)
	}

	_, err = db.Exec("PRAGMA synchronous=NORMAL")
	if err != nil {
		return fmt.Errorf("failed to set synchronous mode: %v", err)
	}

	return nil
}
