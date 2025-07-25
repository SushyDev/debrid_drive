package repository

import (
	"database/sql"

	real_debrid_api "github.com/sushydev/real_debrid_go/api"
	"github.com/sushydev/vfs_go/interfaces"
)

type TorrentFile struct {
	identifier        uint64
	torrentIdentifier string
	torrentFileIndex  int
	path              string
	size              int
	link              string
	fsNodeIdentifier  uint64
}

func (torrentFile *TorrentFile) GetIdentifier() uint64 {
	return torrentFile.identifier
}

func (torrentFile *TorrentFile) GetPath() string {
	return torrentFile.path
}

func (torrentFile *TorrentFile) GetSize() int {
	return torrentFile.size
}

func (torrentFile *TorrentFile) GetLink() string {
	return torrentFile.link
}

func (torrentFile *TorrentFile) GetFileIdentifier() uint64 {
	return torrentFile.fsNodeIdentifier
}

func (mediaService *MediaRepository) GetTorrentFileByFileId(identifier uint64) (*TorrentFile, error) {
	query := `
	SELECT id, torrent_id, path, size, link, file_index, file_node_id
	FROM torrent_files
	WHERE file_node_id = ?;
	`

	row := mediaService.database.QueryRow(query, identifier)

	torrentFile := &TorrentFile{}
	err := row.Scan(
		&torrentFile.identifier,
		&torrentFile.torrentIdentifier,
		&torrentFile.path,
		&torrentFile.size,
		&torrentFile.link,
		&torrentFile.torrentFileIndex,
		&torrentFile.fsNodeIdentifier,
	)

	if err != nil {
		return nil, err
	}

	return torrentFile, nil
}

func (mediaService *MediaRepository) AddTorrentFile(transaction *sql.Tx, databaseTorrent *Torrent, torrentFile real_debrid_api.TorrentFile, fileNode interfaces.Node, link string, index int) (*TorrentFile, error) {
	query := `
	INSERT INTO torrent_files (torrent_id, path, size, link, file_index, file_node_id)
	VALUES (?, ?, ?, ?, ?, ?)
	RETURNING id, torrent_id, path, size, link, file_index, file_node_id;
	`

	row := transaction.QueryRow(query, databaseTorrent.identifier, torrentFile.Path, torrentFile.Bytes, link, index, fileNode.GetId())

	databaseTorrentFile := &TorrentFile{}
	err := row.Scan(
		&databaseTorrentFile.identifier,
		&databaseTorrentFile.torrentIdentifier,
		&databaseTorrentFile.path,
		&databaseTorrentFile.size,
		&databaseTorrentFile.link,
		&databaseTorrentFile.torrentFileIndex,
		&databaseTorrentFile.fsNodeIdentifier,
	)

	if err != nil {
		return nil, mediaService.error("Failed to scan data", err)
	}

	return databaseTorrentFile, nil
}

func (mediaService *MediaRepository) RemoveTorrentFile(transaction *sql.Tx, torrentFile *TorrentFile) error {
	query := `
	DELETE FROM torrent_files
	WHERE id = ?;
	`

	_, err := transaction.Exec(query, torrentFile.identifier)
	if err != nil {
		return mediaService.error("Failed to delete data", err)
	}

	return nil
}

func (mediaService *MediaRepository) GetTorrentFiles(torrent *Torrent) ([]*TorrentFile, error) {
	query := `
	SELECT id, torrent_id, path, size, link, file_index, file_node_id
	FROM torrent_files
	WHERE torrent_id = ?
	`

	rows, err := mediaService.database.Query(query, torrent.identifier)
	if err != nil {
		return nil, mediaService.error("Failed to query data", err)
	}
	defer rows.Close()

	torrentFiles := make([]*TorrentFile, 0)
	for rows.Next() {
		torrentFile := &TorrentFile{}

		err := rows.Scan(
			&torrentFile.identifier,
			&torrentFile.torrentIdentifier,
			&torrentFile.path,
			&torrentFile.size,
			&torrentFile.link,
			&torrentFile.torrentFileIndex,
			&torrentFile.fsNodeIdentifier,
		)

		if err != nil {
			return nil, mediaService.error("Failed to scan data", err)
		}

		torrentFiles = append(torrentFiles, torrentFile)
	}

	return torrentFiles, nil
}
