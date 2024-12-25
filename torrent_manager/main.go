package torrent_manager

import (
	"database/sql"
	"fmt"

	"debrid_drive/config"
	"debrid_drive/database"

	real_debrid "github.com/sushydev/real_debrid_go"
	real_debrid_api "github.com/sushydev/real_debrid_go/api"
	vfs "github.com/sushydev/vfs_go"
	"github.com/sushydev/vfs_go/node"
)

type Instance struct {
	client     *real_debrid.Client
	database   *database.Instance
	fileSystem *vfs.FileSystem
}

func NewInstance(client *real_debrid.Client, database *database.Instance, fileSystem *vfs.FileSystem) *Instance {
	return &Instance{
		client:     client,
		database:   database,
		fileSystem: fileSystem,
	}
}

func (instance *Instance) GetNewTorrentsDir() (*node.Directory, error) {
	return instance.fileSystem.FindOrCreateDirectory("new_torrents", instance.fileSystem.GetRoot())
}

func (instance *Instance) NewTransaction() (*sql.Tx, error) {
	return instance.database.NewTransaction()
}

func (instance *Instance) GetTorrentFileByFile(file *node.File) (*database.TorrentFile, error) {
	return instance.database.GetTorrentFileByFileId(file.GetIdentifier())
}

func (instance *Instance) GetTorrentByTorrentFile(torrentFile *database.TorrentFile) (*database.Torrent, error) {
	return instance.database.GetTorrentByTorrentFileId(torrentFile.GetIdentifier())
}

func (instance *Instance) TorrentExists(transaction *sql.Tx, torrent *real_debrid_api.Torrent) (bool, error) {
	return instance.database.TorrentExists(transaction, torrent.ID)
}

// 1. Create directory for torrent
// 2. Add torrent to database
// 3. For each file in torrent files:
// -- 1. Create file for torrent file
// -- 2. Add torrent file to database
func (instance *Instance) AddTorrent(transaction *sql.Tx, torrent *real_debrid_api.Torrent) error {
	newTorrentsDir, err := instance.GetNewTorrentsDir()
	if err != nil {
		return fmt.Errorf("Failed to get new torrents directory: %v", err)
	}

	directory, err := instance.fileSystem.FindOrCreateDirectory(torrent.ID, newTorrentsDir)
	if err != nil {
		return fmt.Errorf("Failed to create directory: %v", err)
	}

	databaseTorrent, err := instance.database.AddTorrent(transaction, torrent)
	if err != nil {
		return fmt.Errorf("Failed to add torrent to database: %v", err)
	}

	torrentInfo, err := real_debrid_api.GetTorrentInfo(instance.client, torrent.ID)
	if err != nil {
		return fmt.Errorf("Failed to get torrent info: %v", err)
	}

	skippedFiles := 0
	for index, torrentFile := range torrentInfo.Files {
		if torrentFile.Selected == 0 {
			skippedFiles++
			continue
		}

		name := torrentFile.Path[1:]
		link := torrentInfo.Links[index-skippedFiles]

		fileNode, err := instance.fileSystem.FindOrCreateFile(name, directory, config.GetContentType(), "")
		if err != nil {
			return fmt.Errorf("Failed to create file: %v", err)
		}

		_, err = instance.database.AddTorrentFile(transaction, databaseTorrent, torrentFile, fileNode, link, index)
		if err != nil {
			return fmt.Errorf("Failed to add torrent file: %v", err)
		}
	}

	return nil
}

// 1. Remove torrent files
// 2. Remove torrent from database
// 3. Remove torrent from API
func (instance *Instance) DeleteTorrent(transaction *sql.Tx, torrent *database.Torrent) error {
	var err error

	err = instance.removeTorrentFiles(transaction, torrent)
	if err != nil {
		return fmt.Errorf("Failed to remove torrent files: %v", err)
	}

	err = instance.removeTorrentFromDatabase(transaction, torrent)
	if err != nil {
		return fmt.Errorf("Failed to remove torrent from database: %v", err)
	}

	err = instance.removeTorrentFromApi(torrent)
	if err != nil {
		return fmt.Errorf("Failed to delete torrent from api: %v", err)
	}

	return nil
}

// Removes from database and file system
func (instance *Instance) removeTorrentFiles(transaction *sql.Tx, databaseTorrent *database.Torrent) error {
	torrentFiles, err := instance.database.GetTorrentFiles(transaction, databaseTorrent)
	if err != nil {
		return fmt.Errorf("Failed to get torrent files: %v", err)
	}

	for _, torrentFile := range torrentFiles {
		err = instance.database.RemoveTorrentFile(transaction, torrentFile)
		if err != nil {
			return fmt.Errorf("Failed to remove torrent file: %v", err)
		}

		vfsFile, err := instance.fileSystem.GetFile(torrentFile.GetFileIdentifier())
		if err != nil {
			return fmt.Errorf("Failed to get file: %v", err)
		}

		if vfsFile == nil {
			continue
		}

		err = instance.fileSystem.DeleteFile(vfsFile)
		if err != nil {
			return fmt.Errorf("Failed to delete file: %v", err)
		}
	}

	return nil
}

func (instance *Instance) removeTorrentFromDatabase(transaction *sql.Tx, databaseTorrent *database.Torrent) error {
	return instance.database.RemoveTorrent(transaction, databaseTorrent)
}

func (instance *Instance) removeTorrentFromApi(torrent *database.Torrent) error {
	return real_debrid_api.Delete(instance.client, torrent.GetTorrentIdentifier())
}

func (instance *Instance) GetTorrents(transaction *sql.Tx) ([]*database.Torrent, error) {
	return instance.database.GetTorrents(transaction)
}
