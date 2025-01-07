package manager

import (
	"database/sql"
	"fmt"

	"debrid_drive/config"
	"debrid_drive/database"

	media_service "debrid_drive/media/service"

	real_debrid "github.com/sushydev/real_debrid_go"
	real_debrid_api "github.com/sushydev/real_debrid_go/api"
	vfs "github.com/sushydev/vfs_go"
	"github.com/sushydev/vfs_go/node"
)

type MediaManager struct {
	client       *real_debrid.Client
	database     *database.Instance
	fileSystem   *vfs.FileSystem
	mediaService *media_service.MediaService
}

func NewMediaManager(client *real_debrid.Client, database *database.Instance, fileSystem *vfs.FileSystem, mediaService *media_service.MediaService) *MediaManager {
	return &MediaManager{
		client:       client,
		database:     database,
		fileSystem:   fileSystem,
		mediaService: mediaService,
	}
}

func (instance *MediaManager) error(message string, err error) error {
	return fmt.Errorf("%s\n%w", message, err)
}

func (instance *MediaManager) GetNewTorrentsDir() (*node.Directory, error) {
	return instance.fileSystem.FindOrCreateDirectory("media_manager", instance.fileSystem.GetRoot())
}

func (instance *MediaManager) NewTransaction() (*sql.Tx, error) {
	return instance.database.NewTransaction()
}

func (instance *MediaManager) GetTorrentFileByFile(file *node.File) (*media_service.TorrentFile, error) {
	torrentFile, err := instance.mediaService.GetTorrentFileByFileId(file.GetIdentifier())
	if err != nil {
		return nil, instance.error("Failed to get torrent file by file id", err)
	}

	return torrentFile, nil
}

func (instance *MediaManager) GetTorrentByTorrentFile(torrentFile *media_service.TorrentFile) (*media_service.Torrent, error) {
	torrent, err := instance.mediaService.GetTorrentByTorrentFileId(torrentFile.GetIdentifier())
	if err != nil {
		return nil, instance.error("Failed to get torrent by torrent file id", err)
	}

	return torrent, nil
}

func (instance *MediaManager) TorrentExists(torrent *real_debrid_api.Torrent) (bool, error) {
	return instance.mediaService.TorrentExists(torrent.ID)
}

// 1. Create directory for torrent
// 2. Add torrent to database
// 3. For each file in torrent files:
// -- 1. Create file for torrent file
// -- 2. Add torrent file to database
func (instance *MediaManager) AddTorrent(transaction *sql.Tx, torrent *real_debrid_api.Torrent) error {
	newTorrentsDir, err := instance.GetNewTorrentsDir()
	if err != nil {
		return instance.error("Failed to get new torrents directory", err)
	}

	directory, err := instance.fileSystem.FindOrCreateDirectory(torrent.ID, newTorrentsDir)
	if err != nil {
		return instance.error("Failed to create directory", err)
	}

	databaseTorrent, err := instance.mediaService.AddTorrent(transaction, torrent)
	if err != nil {
		return instance.error("Failed to add torrent to database", err)
	}

	torrentInfo, err := real_debrid_api.GetTorrentInfo(instance.client, torrent.ID)
	if err != nil {
		return instance.error("Failed to get torrent info", err)
	}

	selectedFiles := make([]real_debrid_api.TorrentFile, 0)
	for _, torrentFile := range torrentInfo.Files {
		if torrentFile.Selected != 1 {
			continue
		}

		selectedFiles = append(selectedFiles, torrentFile)
	}

	if len(selectedFiles) > len(torrentInfo.Links) {
		err := fmt.Errorf("Torrent has more files than links (Most likely an archive) Files: %d, Links: %d", len(torrentInfo.Files), len(torrentInfo.Links))
		rejectErr := instance.mediaService.RejectTorrent(transaction, torrent)
		if rejectErr != nil {
			return instance.error("Torrent got rejected but failed", rejectErr)
		}

		return instance.error("Rejected", err)
	}

	for index, torrentFile := range selectedFiles {
		name := torrentFile.Path[1:]

		if index >= len(torrentInfo.Links) {
			return instance.error("Link index out of bounds", nil)
		}

		link := torrentInfo.Links[index]

		fileNode, err := instance.fileSystem.FindOrCreateFile(name, directory, config.GetContentType(), "")
		if err != nil {
			return instance.error("Failed to create file", err)
		}

		_, err = instance.mediaService.AddTorrentFile(transaction, databaseTorrent, torrentFile, fileNode, link, index)
		if err != nil {
			return instance.error("Failed to add torrent file to database", err)
		}
	}

	return nil
}

// 1. Remove torrent files
// 2. Remove torrent from database
// 3. Remove torrent from API
func (instance *MediaManager) DeleteTorrent(transaction *sql.Tx, torrent *media_service.Torrent) error {
	var err error

	err = instance.removeTorrentFiles(transaction, torrent)
	if err != nil {
		return instance.error("Failed to remove torrent files", err)
	}

	err = instance.removeTorrentFromDatabase(transaction, torrent)
	if err != nil {
		return instance.error("Failed to remove torrent from database", err)
	}

	err = instance.removeTorrentFromApi(torrent)
	if err != nil {
		return instance.error("Failed to delete torrent from api", err)
	}

	return nil
}

// Removes from database and file system
func (instance *MediaManager) removeTorrentFiles(transaction *sql.Tx, databaseTorrent *media_service.Torrent) error {
	torrentFiles, err := instance.mediaService.GetTorrentFiles(databaseTorrent)
	if err != nil {
		return instance.error("Failed to get torrent files", err)
	}

	for _, torrentFile := range torrentFiles {
		err = instance.mediaService.RemoveTorrentFile(transaction, torrentFile)
		if err != nil {
			return instance.error("Failed to remove torrent file", err)
		}

		vfsFile, err := instance.fileSystem.GetFile(torrentFile.GetFileIdentifier())
		if err != nil {
			return instance.error("Failed to get file", err)
		}

		if vfsFile == nil {
			continue
		}

		err = instance.fileSystem.DeleteFile(vfsFile)
		if err != nil {
			return instance.error("Failed to delete file", err)
		}
	}

	return nil
}

func (instance *MediaManager) removeTorrentFromDatabase(transaction *sql.Tx, databaseTorrent *media_service.Torrent) error {
	return instance.mediaService.RemoveTorrent(transaction, databaseTorrent)
}

func (instance *MediaManager) removeTorrentFromApi(torrent *media_service.Torrent) error {
	return real_debrid_api.Delete(instance.client, torrent.GetTorrentIdentifier())
}

func (instance *MediaManager) GetTorrents() ([]*media_service.Torrent, error) {
	return instance.mediaService.GetTorrents()
}
