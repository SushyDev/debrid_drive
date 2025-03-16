package poller

import (
	"database/sql"
	"fmt"
	"time"

	"debrid_drive/config"
	"debrid_drive/logger"

	media_repository "debrid_drive/media/repository"
	media_service "debrid_drive/media/service"

	real_debrid "github.com/sushydev/real_debrid_go"
	real_debrid_api "github.com/sushydev/real_debrid_go/api"
)

type Poller struct {
	client       *real_debrid.Client
	mediaService *media_service.MediaService
	logger       *logger.Logger
}

func NewPoller(client *real_debrid.Client, mediaService *media_service.MediaService) *Poller {
	logger, err := logger.NewLogger("Poller")
	if err != nil {
		panic(err)
	}

	return &Poller{
		client:       client,
		mediaService: mediaService,
		logger:       logger,
	}
}

func (instance *Poller) Cron() {
	interval := config.GetPollIntervalSeconds()

	for {
		<-time.After(interval)

		err := instance.Poll()
		if err != nil {
			instance.logger.Error("Failed to poll", err)
		}
	}
}

func (instance *Poller) Poll() error {
	instance.logger.Info("Polling started")

	torrents, err := real_debrid_api.GetTorrents(instance.client, 1000, 1)
	if err != nil {
		return err
	}

	instance.checkNewEntries(*torrents)
	instance.checkRemovedEntries(*torrents)

	instance.logger.Info("Polling complete")

	return nil
}

func (instance *Poller) checkNewEntries(torrents real_debrid_api.Torrents) {
	transaction, err := instance.mediaService.NewTransaction()
	if err != nil {
		instance.logger.Error("Failed to begin transaction", err)
		return
	}
	defer transaction.Rollback()

	for _, torrent := range GetEntries(torrents) {
		_, err := transaction.Exec("SAVEPOINT add_entry")
		if err != nil {
			instance.logger.Error("Failed to create savepoint", err)
			continue
		}

		exists, err := instance.mediaService.TorrentExists(torrent)
		if err != nil {
			transaction.Exec("ROLLBACK TO SAVEPOINT add_entry")
			instance.logger.Error("Failed to check if torrent exists", err)
			return
		}

		if exists {
			transaction.Exec("ROLLBACK TO SAVEPOINT add_entry")
			instance.logger.Info(fmt.Sprintf("Entry already exists:	%s - %s", torrent.ID, torrent.Filename))
			continue
		}

		rejected, err := instance.mediaService.TorrentRejected(torrent)
		if err != nil {
			transaction.Exec("ROLLBACK TO SAVEPOINT add_entry")
			instance.logger.Error("Failed to check if torrent is rejected", err)
			return
		}

		if rejected {
			transaction.Exec("ROLLBACK TO SAVEPOINT add_entry")
			instance.logger.Info(fmt.Sprintf("Entry is rejected:	%s - %s", torrent.ID, torrent.Filename))
			continue
		}

		err = instance.mediaService.AddTorrent(transaction, torrent)
		if err != nil {
			switch err.(type) {
			case media_service.TorrentRejectedError:
				instance.mediaService.RejectTorrent(transaction, torrent)
				instance.logger.Info(fmt.Sprintf("Rejected entry:	%s - %s", torrent.ID, torrent.Filename))
				break
			default:
				transaction.Exec("ROLLBACK TO SAVEPOINT add_entry")
				instance.logger.Error(fmt.Sprintf("Failed to add torrent: %s - %s", torrent.ID, torrent.Filename), err)
				continue
			}

		}

		instance.logger.Info(fmt.Sprintf("Added entry:	%s [%s]", torrent.Filename, torrent.ID))

		transaction.Exec("RELEASE SAVEPOINT add_entry")
	}

	err = transaction.Commit()
	if err != nil {
		instance.logger.Error("Failed to commit transaction", err)
		return
	}
}

func (instance *Poller) checkRemovedEntries(torrents real_debrid_api.Torrents) {
	torrentMap := make(map[string]bool)
	for _, torrent := range torrents {
		torrentMap[torrent.ID] = true
	}

	transaction, err := instance.mediaService.NewTransaction()
	if err != nil {
		instance.logger.Error("Failed to begin transaction", err)
		return
	}
	defer transaction.Rollback()

	databaseTorrents, err := instance.mediaService.GetTorrents()
	if err != nil {
		instance.logger.Error("Failed to get torrents", err)
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
		instance.logger.Error("Failed to commit transaction", err)
		return
	}
}

func (instance *Poller) removeEntry(transaction *sql.Tx, databaseTorrent *media_repository.Torrent) {
	instance.mediaService.DeleteTorrent(transaction, databaseTorrent)
}
