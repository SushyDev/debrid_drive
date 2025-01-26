package service

import (
	"database/sql"
	"fmt"

	"debrid_drive/config"
	"debrid_drive/database"
	"debrid_drive/logger"

	media_repository "debrid_drive/media/repository"

	real_debrid "github.com/sushydev/real_debrid_go"
	real_debrid_api "github.com/sushydev/real_debrid_go/api"
	vfs "github.com/sushydev/vfs_go"
	"github.com/sushydev/vfs_go/node"
)

type MediaService struct {
	client          *real_debrid.Client
	database        *database.Instance
	fileSystem      *vfs.FileSystem
	mediaRepository *media_repository.MediaRepository
	logger          *logger.Logger
}

// create new error type named RejectedError

var _ error = TorrentRejectedError{}

type TorrentRejectedError struct {}

func (TorrentRejectedError) Error() string {
	return "Rejected"
}


func NewMediaService(client *real_debrid.Client, database *database.Instance, fileSystem *vfs.FileSystem, mediaRepository *media_repository.MediaRepository) *MediaService {
	logger, err := logger.NewLogger("Media Service")
	if err != nil {
		panic(err)
	}

	return &MediaService{
		client:          client,
		database:        database,
		fileSystem:      fileSystem,
		mediaRepository: mediaRepository,
		logger:          logger,
	}
}

func (instance *MediaService) error(message string, err error) error {
	instance.logger.Error(message, err)
	return fmt.Errorf("%s\n%w", message, err)
}

func (instance *MediaService) GetManagerDirectory() (*node.Directory, error) {
	return instance.fileSystem.FindOrCreateDirectory("media_manager", instance.fileSystem.GetRoot())
}

func (instance *MediaService) NewTransaction() (*sql.Tx, error) {
	return instance.database.NewTransaction()
}

func (instance *MediaService) GetTorrentFileByFile(file *node.File) (*media_repository.TorrentFile, error) {
	torrentFile, err := instance.mediaRepository.GetTorrentFileByFileId(file.GetIdentifier())
	if err != nil {
		instance.logger.Error("Failed to get torrent file by file id", err)
		return nil, err
	}

	return torrentFile, nil
}

func (instance *MediaService) GetTorrentByTorrentFile(torrentFile *media_repository.TorrentFile) (*media_repository.Torrent, error) {
	torrent, err := instance.mediaRepository.GetTorrentByTorrentFileId(torrentFile.GetIdentifier())
	if err != nil {
		instance.logger.Error("Failed to get torrent by torrent file id", err)
		return nil, err
	}

	return torrent, nil
}

func (instance *MediaService) TorrentExists(torrent *real_debrid_api.Torrent) (bool, error) {
	return instance.mediaRepository.TorrentExists(torrent.ID)
}

func (instance *MediaService) TorrentRejected(torrent *real_debrid_api.Torrent) (bool, error) {
	return instance.mediaRepository.TorrentRejected(torrent.ID)
}

// 1. Create directory for torrent
// 2. Add torrent to database
// 3. For each file in torrent files:
// -- 1. Create file for torrent file
// -- 2. Add torrent file to database
func (instance *MediaService) AddTorrent(transaction *sql.Tx, torrent *real_debrid_api.Torrent) error {
	managerDirectory, err := instance.GetManagerDirectory()
	if err != nil {
		instance.logger.Error("Failed to get new torrents directory", err)
		return err
	}

	var torrentDirectory string

	if config.GetUseFilenameInLister() {
		torrentDirectory = torrent.Filename
	} else {
		torrentDirectory = torrent.ID
	}

	directory, err := instance.fileSystem.FindOrCreateDirectory(torrentDirectory, managerDirectory)
	if err != nil {
		instance.logger.Error("Failed to create directory", err)
		return err
	}

	databaseTorrent, err := instance.mediaRepository.AddTorrent(transaction, torrent)
	if err != nil {
		instance.logger.Error("Failed to add torrent to database", err)
		return err
	}

	torrentInfo, err := real_debrid_api.GetTorrentInfo(instance.client, torrent.ID)
	if err != nil {
		instance.logger.Error("Failed to get torrent info", err)
		return err
	}

	selectedFiles := make([]real_debrid_api.TorrentFile, 0)
	for _, torrentFile := range torrentInfo.Files {
		if torrentFile.Selected != 1 {
			continue
		}

		selectedFiles = append(selectedFiles, torrentFile)
	}

	if len(selectedFiles) > len(torrentInfo.Links) {
		return TorrentRejectedError{}
	}

	for index, torrentFile := range selectedFiles {
		name := torrentFile.Path[1:]

		if index >= len(torrentInfo.Links) {
			instance.logger.Error("Link index out of bounds", nil)
			return err
		}

		link := torrentInfo.Links[index]

		fileNode, err := instance.fileSystem.FindOrCreateFile(name, directory, config.GetContentType(), "")
		if err != nil {
			instance.logger.Error("Failed to create file", err)
			return err
		}

		_, err = instance.mediaRepository.AddTorrentFile(transaction, databaseTorrent, torrentFile, fileNode, link, index)
		if err != nil {
			instance.logger.Error("Failed to add torrent file to database", err)
			return err
		}
	}

	return nil
}

func (instance *MediaService) RejectTorrent(transaction *sql.Tx, torrent *real_debrid_api.Torrent) error {
	return instance.mediaRepository.RejectTorrent(transaction, torrent)
}

// 1. Remove torrent files
// 2. Remove torrent from database
// 3. Remove torrent from API
func (instance *MediaService) DeleteTorrent(transaction *sql.Tx, torrent *media_repository.Torrent) error {
	var err error

	err = instance.removeTorrentFiles(transaction, torrent)
	if err != nil {
		instance.logger.Error("Failed to remove torrent files", err)
		return err
	}

	err = instance.removeTorrentFromDatabase(transaction, torrent)
	if err != nil {
		instance.logger.Error("Failed to remove torrent from database", err)
		return err
	}

	err = instance.removeTorrentFromApi(torrent)
	if err != nil {
		instance.logger.Error("Failed to delete torrent from api", err)
		return err
	}

	return nil
}

// Removes from database and file system
func (instance *MediaService) removeTorrentFiles(transaction *sql.Tx, databaseTorrent *media_repository.Torrent) error {
	torrentFiles, err := instance.mediaRepository.GetTorrentFiles(databaseTorrent)
	if err != nil {
		instance.logger.Error("Failed to get torrent files", err)
		return err
	}

	for _, torrentFile := range torrentFiles {
		err = instance.mediaRepository.RemoveTorrentFile(transaction, torrentFile)
		if err != nil {
			instance.logger.Error("Failed to remove torrent file", err)
			return err
		}

		vfsFile, err := instance.fileSystem.GetFile(torrentFile.GetFileIdentifier())
		if err != nil {
			instance.logger.Error("Failed to get file", err)
			return err
		}

		if vfsFile == nil {
			continue
		}

		err = instance.fileSystem.DeleteFile(vfsFile)
		if err != nil {
			instance.logger.Error("Failed to delete file", err)
			return err
		}
	}

	return nil
}

func (instance *MediaService) removeTorrentFromDatabase(transaction *sql.Tx, databaseTorrent *media_repository.Torrent) error {
	return instance.mediaRepository.RemoveTorrent(transaction, databaseTorrent)
}

func (instance *MediaService) removeTorrentFromApi(torrent *media_repository.Torrent) error {
	return real_debrid_api.Delete(instance.client, torrent.GetTorrentIdentifier())
}

func (instance *MediaService) GetTorrents() ([]*media_repository.Torrent, error) {
	return instance.mediaRepository.GetTorrents()
}
