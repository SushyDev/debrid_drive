package main

import (
	"flag"
	"fmt"
	"log"

	"debrid_drive/api"
	"debrid_drive/database"
	"debrid_drive/poller"
	"debrid_drive/torrent_manager"

	"github.com/sushydev/real_debrid_go"
	vfs "github.com/sushydev/vfs_go"
)

func main() {
	fmt.Println("Real Debrid client created")

	flag.Parse()
	args := flag.Args()

	if len(args) == 0 {
		log.Fatalf("No token provided")
	}

	token := args[0]

	log.Printf("Token: %s", token)

	db, err := database.NewInstance()
	if err != nil {
		log.Fatalf("Failed to create database: %v", err)
	}

	client := real_debrid_go.NewClient(token)

	fileSystem, err := vfs.NewFileSystem("debrid_drive", "./file_system.db")
	if err != nil {
		log.Fatalf("Failed to create file system: %v", err)
	}

	torrentManager := torrent_manager.NewInstance(client, db, fileSystem)

	go func() {
		err = api.NewApi(client, fileSystem, torrentManager)
		if err != nil {
			log.Fatalf("Failed to create API: %v", err)
		}
	}()

	poller := poller.NewInstance(client, torrentManager)

	poller.Poll()
}
