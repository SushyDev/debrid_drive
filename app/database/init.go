package database

import (
	"database/sql"
)

func enableWAL(db *sql.DB) error {
	_, err := db.Exec("PRAGMA journal_mode=WAL")
	if err != nil {
		return err
	}

	_, err = db.Exec("PRAGMA synchronous=NORMAL")
	if err != nil {
		return err
	}

	return nil
}

func createTorrentsTable(db *sql.DB) error {
	_, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS torrents (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			torrent_id TEXT NOT NULL,
			name TEXT NOT NULL,

			UNIQUE(torrent_id)
		);
	`)

	return err
}

func createIndecesOnTorrentsTable(db *sql.DB) error {
	_, err := db.Exec(`
		CREATE INDEX IF NOT EXISTS idx_torrents_torrent_id 
		ON torrents (torrent_id);
	`)

	return err
}

func createTorrentFilesTable(db *sql.DB) error {
	_, err := db.Exec(`
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

	return err
}

func createRejectedTorrentsTable(db *sql.DB) error {
	_, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS rejected_torrents (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			torrent_id TEXT NOT NULL,
			name TEXT NOT NULL,
				
			UNIQUE(torrent_id)
		);
	`)

	return err
}
