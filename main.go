package main

import (
	"log"

	"debrid_drive/api"
	"debrid_drive/config"
	"debrid_drive/database"
	"debrid_drive/poller"
	"debrid_drive/torrent_manager"

	"github.com/sushydev/real_debrid_go"
	vfs "github.com/sushydev/vfs_go"
)

func main() {
    config.Validate()

	token := config.GetRealDebridToken()
	client := real_debrid_go.NewClient(token)

	database, err := database.NewInstance()
	if err != nil {
		log.Fatalf("Failed to create database: %v", err)
	}

	fileSystem, err := vfs.NewFileSystem("debrid_drive", "./file_system.db")
	if err != nil {
		log.Fatalf("Failed to create file system: %v", err)
	}

	torrentManager := torrent_manager.NewInstance(client, database, fileSystem)

	go func() {
		err = api.NewApi(client, fileSystem, torrentManager)
		if err != nil {
			log.Fatalf("Failed to create API: %v", err)
		}
	}()

	poller := poller.NewInstance(client, torrentManager)
	poller.Poll()
}
