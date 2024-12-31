package poller

import (
	"fmt"
	"database/sql"
	"time"

	"debrid_drive/logger"

	media_manager "debrid_drive/media/manager"
	media_service "debrid_drive/media/service"

	real_debrid "github.com/sushydev/real_debrid_go"
	real_debrid_api "github.com/sushydev/real_debrid_go/api"
)

type Poller struct {
	client       *real_debrid.Client
	mediaManager *media_manager.MediaManager
	logger       *logger.Logger
}

func NewPoller(client *real_debrid.Client, mediaManager *media_manager.MediaManager) *Poller {
	logger, err := logger.NewLogger("Poller")
	if err != nil {
		logger.Error("Failed to get logger: %v", err)
		return nil
	}

	return &Poller{
		client:       client,
		mediaManager: mediaManager,
		logger:       logger,
	}
}

func (instance *Poller) error(message string, err error) {
	instance.logger.Error(message, err)
}

func (instance *Poller) Poll() {
	for {
		torrents, err := real_debrid_api.GetTorrents(instance.client)
		if err != nil {
			instance.error("Failed to get torrents", err)
			time.Sleep(30 * time.Second)
			continue
		}

		instance.checkNewEntries(*torrents)
		instance.checkRemovedEntries(*torrents)

		time.Sleep(30 * time.Second)
	}
}

func (instance *Poller) checkNewEntries(torrents real_debrid_api.Torrents) {
	transaction, err := instance.mediaManager.NewTransaction()
	if err != nil {
		instance.error("Failed to begin transaction", err)
		return
	}
	defer transaction.Rollback()

	for _, torrent := range torrents {
		exists, err := instance.mediaManager.TorrentExists(torrent)
		if err != nil {
			instance.error("Failed to check if torrent exists", err)
			return
		}

		if exists {
			continue
		}

		if torrent.Status != "downloaded" {
			continue
		}

		instance.logger.Info(fmt.Sprintf("Adding entry:	%s - %s", torrent.ID, torrent.Filename))

		err = instance.mediaManager.AddTorrent(transaction, torrent)
		if err != nil {
			instance.error("Failed to add new entry", err)
			return
		}
	}

	err = transaction.Commit()
	if err != nil {
		instance.error("Failed to commit transaction", err)
		return
	}
}

func (instance *Poller) checkRemovedEntries(torrents real_debrid_api.Torrents) {
	torrentMap := make(map[string]bool)
	for _, torrent := range torrents {
		torrentMap[torrent.ID] = true
	}

	transaction, err := instance.mediaManager.NewTransaction()
	if err != nil {
		instance.error("Failed to begin transaction", err)
		return
	}
	defer transaction.Rollback()

	databaseTorrents, err := instance.mediaManager.GetTorrents()
	if err != nil {
		instance.error("Failed to get torrents", err)
		return
	}

	for _, databaseTorrent := range databaseTorrents {
		_, ok := torrentMap[databaseTorrent.GetTorrentIdentifier()]
		if ok {
			continue
		}

		instance.logger.Info(fmt.Sprintf("Removing entry:	%s - %s", databaseTorrent.GetTorrentIdentifier(), databaseTorrent.GetName()))

		instance.removeEntry(transaction, databaseTorrent)
	}

	err = transaction.Commit()
	if err != nil {
		instance.error("Failed to commit transaction", err)
		return
	}
}

func (instance *Poller) removeEntry(transaction *sql.Tx, databaseTorrent *media_service.Torrent) {
	instance.mediaManager.DeleteTorrent(transaction, databaseTorrent)
}
