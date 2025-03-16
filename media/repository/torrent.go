package repository

import (
	"database/sql"

	real_debrid_api "github.com/sushydev/real_debrid_go/api"
)

type Torrent struct {
	identifier        uint64
	torrentIdentifier string
	name              string
}

func (torrent *Torrent) GetIdentifier() uint64 {
	return torrent.identifier
}

func (torrent *Torrent) GetTorrentIdentifier() string {
	return torrent.torrentIdentifier
}

func (torrent *Torrent) GetName() string {
	return torrent.name
}

func (mediaRepository *MediaRepository) TorrentExists(torrentId string) (bool, error) {
	query := `
	SELECT EXISTS(SELECT 1 FROM torrents WHERE torrent_id = ?)
	`

	row := mediaRepository.database.QueryRow(query, torrentId)

	var exists int
	err := row.Scan(&exists)
	if err != nil {
		return false, err
	}

	return exists == 1, nil
}

func (mediaRepository *MediaRepository) TorrentRejected(torrentId string) (bool, error) {
	query := `
	SELECT EXISTS(SELECT 1 FROM rejected_torrents WHERE torrent_id = ?)
	`

	row := mediaRepository.database.QueryRow(query, torrentId)

	var exists int
	err := row.Scan(&exists)
	if err != nil {
		return false, err
	}

	return exists == 1, nil
}

func (mediaRepository *MediaRepository) AddTorrent(transaction *sql.Tx, torrent *real_debrid_api.Torrent) (*Torrent, error) {
	query := `
	INSERT INTO torrents (torrent_id, name)
	VALUES (?, ?)
	RETURNING id, torrent_id, name;
	`

	row := transaction.QueryRow(query, torrent.ID, torrent.Filename)

	databaseTorrent := &Torrent{}
	err := row.Scan(
		&databaseTorrent.identifier,
		&databaseTorrent.torrentIdentifier,
		&databaseTorrent.name,
	)

	if err != nil {
		return nil, err
	}

	return databaseTorrent, nil
}

func (mediaRepository *MediaRepository) RemoveTorrent(transaction *sql.Tx, torrent *Torrent) error {
	query := `
	DELETE FROM torrents
	WHERE id = ?;
	`

	_, err := transaction.Exec(query, torrent.identifier)
	if err != nil {
		return err
	}

	return nil
}

func (mediaRepository *MediaRepository) RejectTorrent(transaction *sql.Tx, torrent *real_debrid_api.Torrent) error {
	query := `
	INSERT INTO rejected_torrents (torrent_id, name)
	VALUES (?, ?)
	RETURNING id;
	`

	row := transaction.QueryRow(query, torrent.ID, torrent.Filename)

	var identifier uint64
	err := row.Scan(&identifier)
	if err != nil {
		return err
	}

	return nil
}

func (mediaRepository *MediaRepository) GetTorrentByTorrentFileId(torrentFileIdentifier uint64) (*Torrent, error) {
	query := `
	SELECT torrents.id, torrents.torrent_id, torrents.name
	FROM torrents
	LEFT JOIN torrent_files ON torrents.id = torrent_files.torrent_id
	WHERE torrent_files.id = ?
	`

	row := mediaRepository.database.QueryRow(query, torrentFileIdentifier)

	torrent := &Torrent{}
	err := row.Scan(&torrent.identifier, &torrent.torrentIdentifier, &torrent.name)
	if err != nil {
		return nil, err
	}

	return torrent, nil
}

func (mediaRepository *MediaRepository) GetTorrents() ([]*Torrent, error) {
	query := `
	SELECT id, torrent_id, name
	FROM torrents
	`

	rows, err := mediaRepository.database.Query(query)
	if err != nil {
		return nil, err
	}

	torrents := make([]*Torrent, 0)
	for rows.Next() {
		torrent := &Torrent{}
		err := rows.Scan(&torrent.identifier, &torrent.torrentIdentifier, &torrent.name)
		if err != nil {
			return nil, err
		}

		torrents = append(torrents, torrent)
	}

	return torrents, nil
}

func (mediaRepository *MediaRepository) GetRejectedTorrents() ([]*Torrent, error) {
	query := `
	SELECT id, torrent_id, name
	FROM rejected_torrents
	`

	rows, err := mediaRepository.database.Query(query)
	if err != nil {
		return nil, err
	}

	torrents := make([]*Torrent, 0)
	for rows.Next() {
		torrent := &Torrent{}
		err := rows.Scan(&torrent.identifier, &torrent.torrentIdentifier, &torrent.name)
		if err != nil {
			return nil, err
		}

		torrents = append(torrents, torrent)
	}

	return torrents, nil
}
