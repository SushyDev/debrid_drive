package action

import (
	"fmt"

	"debrid_drive/logger"

	media_repository "debrid_drive/media/repository"
	media_service "debrid_drive/media/service"

	real_debrid "github.com/sushydev/real_debrid_go"
	real_debrid_api "github.com/sushydev/real_debrid_go/api"
	"github.com/sushydev/vfs_go/service"

	"github.com/sushydev/vfs_go"
)

type Actioner struct {
	client          *real_debrid.Client
	mediaRepository *media_repository.MediaRepository
	mediaService    *media_service.MediaService
	fileSystem      *filesystem.FileSystem
	logger          *logger.Logger
}

func New(
	client *real_debrid.Client,
	mediaRepository *media_repository.MediaRepository,
	mediaService *media_service.MediaService,
	fileSystem *filesystem.FileSystem,
) *Actioner {
	logger, err := logger.NewLogger("Actioner")
	if err != nil {
		panic(err)
	}

	return &Actioner{
		client:          client,
		mediaRepository: mediaRepository,
		mediaService:    mediaService,
		fileSystem:      fileSystem,
		logger:          logger,
	}
}

func (a *Actioner) Poll() {
	a.logger.Info("Changes detected")

	torrents, err := real_debrid_api.GetTorrents(a.client, 1000, 1)
	if err != nil {
		a.logger.Error("Failed to get torrents", err)
		return
	}

	if torrents == nil {
		a.logger.Error("Empty torrents response from API", nil)
		return
	}

	a.processNewEntries(*torrents)
	a.cleanupRemovedEntries(*torrents)
	a.checkFiles()

	a.logger.Info("Changes processed")
}

func (action *Actioner) processNewEntries(torrents real_debrid_api.Torrents) {
	entries := filterDownloadedEntries(torrents)
	if len(entries) == 0 {
		return
	}

	transaction, err := action.mediaService.NewTransaction()
	if err != nil {
		action.logger.Error("Failed to begin transaction", err)
		return
	}
	defer transaction.Rollback()

	existingTorrents, err := action.mediaService.GetTorrents()
	if err != nil {
		action.logger.Error("Failed to fetch existing torrents", err)
		return
	}

	existingTorrentMap := make(map[string]bool)
	for _, t := range existingTorrents {
		existingTorrentMap[t.GetTorrentIdentifier()] = true
	}

	rejectedTorrents, err := action.mediaService.GetRejectedTorrents()
	if err != nil {
		action.logger.Error("Failed to fetch rejected torrents", err)
		return
	}

	rejectedTorrentMap := make(map[string]bool)
	for _, t := range rejectedTorrents {
		rejectedTorrentMap[t.GetTorrentIdentifier()] = true
	}

	for _, torrent := range entries {
		if existingTorrentMap[torrent.ID] {
			continue
		}

		if rejectedTorrentMap[torrent.ID] {
			continue
		}

		_, err := transaction.Exec("SAVEPOINT add_entry")
		if err != nil {
			action.logger.Error("Failed to create savepoint", err)
			continue
		}

		err = action.mediaService.AddTorrent(transaction, torrent)
		if err != nil {
			switch err.(type) {
			case media_service.TorrentRejectedError:
				if err := action.mediaService.RejectTorrent(transaction, torrent); err != nil {
					transaction.Exec("ROLLBACK TO SAVEPOINT add_entry")
					action.logger.Error(fmt.Sprintf("Failed to reject torrent: %s", torrent.ID), err)
					continue
				}

				action.logger.Info(fmt.Sprintf("Rejected entry: %s [%s]", torrent.Filename, torrent.ID))
			default:
				transaction.Exec("ROLLBACK TO SAVEPOINT add_entry")
				action.logger.Error(fmt.Sprintf("Failed to add torrent: %s [%s]", torrent.Filename, torrent.ID), err)
				continue
			}
		}

		_, err = transaction.Exec("RELEASE SAVEPOINT add_entry")
		if err != nil {
			action.logger.Error("Failed to release savepoint", err)
			continue
		}

		action.logger.Info(fmt.Sprintf("Added entry: %s [%s]", torrent.Filename, torrent.ID))
	}

	if err := transaction.Commit(); err != nil {
		action.logger.Error("Failed to commit transaction", err)
	}
}

func (a *Actioner) cleanupRemovedEntries(torrents real_debrid_api.Torrents) {
	torrentMap := make(map[string]bool, len(torrents))
	for _, torrent := range torrents {
		torrentMap[torrent.ID] = true
	}

	transaction, err := a.mediaService.NewTransaction()
	if err != nil {
		a.logger.Error("Failed to begin transaction", err)
		return
	}
	defer transaction.Rollback()

	databaseTorrents, err := a.mediaService.GetTorrents()
	if err != nil {
		a.logger.Error("Failed to get torrents from database", err)
		return
	}

	for _, dbTorrent := range databaseTorrents {
		_, err := transaction.Exec("SAVEPOINT remove_entry")
		if err != nil {
			a.logger.Error("Failed to create savepoint", err)
			continue
		}

		torrentID := dbTorrent.GetTorrentIdentifier()
		if torrentMap[torrentID] {
			// Exists
			continue
		}

		a.logger.Info(fmt.Sprintf("Removing entry: %s [%s]", dbTorrent.GetName(), torrentID))

		err = a.mediaService.DeleteTorrent(transaction, dbTorrent, false)
		if err != nil {
			a.logger.Error(fmt.Sprintf("Failed to delete torrent: %s", torrentID), err)
			continue
		}

		_, err = transaction.Exec("RELEASE SAVEPOINT remove_entry")
		if err != nil {
			a.logger.Error("Failed to release savepoint", err)
			continue
		}

		a.logger.Info(fmt.Sprintf("Removed entry: %s [%s]", dbTorrent.GetName(), torrentID))
	}

	if err := transaction.Commit(); err != nil {
		a.logger.Error("Failed to commit transaction", err)
	}
}

// Check torrent_files for files that are not in the filesystem
func (a *Actioner) checkFiles() {
	databaseTorrents, err := a.mediaService.GetTorrents()
	if err != nil {
		a.logger.Error("Failed to get torrents", err)
		return
	}

	for _, databaseTorrent := range databaseTorrents {
		torrentFiles, err := a.mediaRepository.GetTorrentFiles(databaseTorrent)
		if err != nil {
			a.logger.Error("Failed to get torrent files", err)
			continue
		}

		for _, torrentFile := range torrentFiles {
			node, err := service.GetFile(a.fileSystem, torrentFile.GetFileIdentifier())
			if err != nil {
				a.logger.Error("Failed to get file node", err)
				continue
			}

			if node != nil {
				continue
			}

			a.logger.Info(fmt.Sprintf("File not found: %d", torrentFile.GetFileIdentifier()))

			tx, err := a.mediaService.NewTransaction()
			if err != nil {
				a.logger.Error("Failed to begin transaction", err)
				continue
			}

			err = a.mediaRepository.RemoveTorrentFile(tx, torrentFile)
			if err != nil {
				a.logger.Error("Failed to remove torrent file", err)
				tx.Rollback()
				continue
			}

			err = tx.Commit()
			if err != nil {
				a.logger.Error("Failed to commit transaction", err)
				continue
			}

			a.logger.Info(fmt.Sprintf("Deleted file: %d", torrentFile.GetFileIdentifier()))
		}
	}

	// for each `torrents` where `torrent_files.torrent_id` is not in `torrents`
	for _, databaseTorrent := range databaseTorrents {
		torrentFiles, err := a.mediaRepository.GetTorrentFiles(databaseTorrent)
		if err != nil {
			a.logger.Error("Failed to get torrent files", err)
			continue
		}

		if len(torrentFiles) > 0 {
			continue
		}

		a.logger.Info(fmt.Sprintf("Removing torrent: %s", databaseTorrent.GetTorrentIdentifier()))

		tx, err := a.mediaService.NewTransaction()
		if err != nil {
			a.logger.Error("Failed to begin transaction", err)
			continue
		}

		err = a.mediaService.DeleteTorrent(tx, databaseTorrent, true)
		if err != nil {
			a.logger.Error("Failed to delete torrent", err)
			tx.Rollback()
			continue
		}

		err = tx.Commit()
		if err != nil {
			a.logger.Error("Failed to commit transaction", err)
			continue
		}

		a.logger.Info(fmt.Sprintf("Deleted torrent: %s", databaseTorrent.GetTorrentIdentifier()))
	}
}

func filterDownloadedEntries(torrents real_debrid_api.Torrents) []*real_debrid_api.Torrent {
	var entries []*real_debrid_api.Torrent

	for _, torrent := range torrents {
		if torrent.Status != "downloaded" || torrent.Bytes == 0 {
			continue
		}

		entries = append(entries, torrent)
	}

	return entries
}

