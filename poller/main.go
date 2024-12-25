package poller

import (
	"database/sql"
	"debrid_drive/database"
	"log"
	"time"

	"debrid_drive/torrent_manager"
	real_debrid "github.com/sushydev/real_debrid_go"
	real_debrid_api "github.com/sushydev/real_debrid_go/api"
)

type Instance struct {
	client         *real_debrid.Client
	torrentManager *torrent_manager.Instance
}

func NewInstance(client *real_debrid.Client, torrentManager *torrent_manager.Instance) *Instance {
	return &Instance{
		client:         client,
		torrentManager: torrentManager,
	}
}

func (instance *Instance) Poll() {
	for {
		torrents, err := real_debrid_api.GetTorrents(instance.client)
		if err != nil {
			log.Printf("Failed to get torrents: %v", err)
			time.Sleep(30 * time.Second)
			continue
		}

		log.Println("Fetched torrents")

		instance.checkNewEntries(*torrents)
		instance.checkRemovedEntries(*torrents)

		time.Sleep(30 * time.Second)
	}
}

func (instance *Instance) checkNewEntries(torrents real_debrid_api.Torrents) {
	transaction, err := instance.torrentManager.NewTransaction()
	if err != nil {
		log.Fatalf("Failed to begin transaction: %v", err)
	}
	defer transaction.Rollback()

	for _, torrent := range torrents {
		exists, err := instance.torrentManager.TorrentExists(transaction, torrent)
		if err != nil {
			log.Fatalf("Failed to scan row: %v", err)
		}

		if exists {
			continue
		}

		err = instance.torrentManager.AddTorrent(transaction, torrent)
		if err != nil {
			log.Fatalf("Failed to add new entry: %v", err)
		}
	}

	err = transaction.Commit()
	if err != nil {
		log.Fatalf("Failed to commit transaction: %v", err)
	}
}

func (instance *Instance) checkRemovedEntries(torrents real_debrid_api.Torrents) {
	torrentMap := make(map[string]bool)
	for _, torrent := range torrents {
		torrentMap[torrent.ID] = true
	}

	transaction, err := instance.torrentManager.NewTransaction()
	if err != nil {
		log.Fatalf("Failed to begin transaction: %v", err)
	}
	defer transaction.Rollback()

	databaseTorrents, err := instance.torrentManager.GetTorrents(transaction)
	if err != nil {
		log.Fatalf("Failed to get torrents: %v", err)
	}

	for _, databaseTorrent := range databaseTorrents {
		_, ok := torrentMap[databaseTorrent.GetTorrentIdentifier()]
		if ok {
			continue
		}

		instance.removeEntry(transaction, databaseTorrent)
	}

	err = transaction.Commit()
	if err != nil {
		log.Fatalf("Failed to commit transaction: %v", err)
	}
}

func (instance *Instance) removeEntry(transaction *sql.Tx, databaseTorrent *database.Torrent) {
	instance.torrentManager.DeleteTorrent(transaction, databaseTorrent)
}
