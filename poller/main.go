package poller

import (
	"database/sql"
	"time"

	"debrid_drive/logger"

	media_manager "debrid_drive/media/manager"
	media_service "debrid_drive/media/service"

	real_debrid "github.com/sushydev/real_debrid_go"
	real_debrid_api "github.com/sushydev/real_debrid_go/api"
	"go.uber.org/zap"
)

type Poller struct {
	client       *real_debrid.Client
	mediaManager *media_manager.MediaManager
	log          *zap.SugaredLogger
}

func NewPoller(client *real_debrid.Client, mediaManager *media_manager.MediaManager) *Poller {
	log, err := logger.GetLogger("poller.log")
	if err != nil {
		log.Fatalf("Failed to get logger: %v", err)
	}

	return &Poller{
		client:       client,
		mediaManager: mediaManager,
		log:          log,
	}
}

func (instance *Poller) error(message string, err error) {
	instance.log.Errorf("%s\n%v", message, err)
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
		exists, err := instance.mediaManager.TorrentExists(transaction, torrent)
		if err != nil {
			instance.error("Failed to check if torrent exists", err)
			return
		}

		if exists {
			continue
		}

		instance.log.Infof("Adding new entry: %s - %s", torrent.ID, torrent.Filename)

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

	databaseTorrents, err := instance.mediaManager.GetTorrents(transaction)
	if err != nil {
		instance.error("Failed to get torrents", err)
		return
	}

	for _, databaseTorrent := range databaseTorrents {
		_, ok := torrentMap[databaseTorrent.GetTorrentIdentifier()]
		if ok {
			continue
		}

		instance.log.Infof("Removing entry: %s - %s", databaseTorrent.GetTorrentIdentifier(), databaseTorrent.GetName())

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
