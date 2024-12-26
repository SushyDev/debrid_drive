package main

import (
	"fmt"

	"debrid_drive/config"
	"debrid_drive/database"
	"debrid_drive/file_system_server"
	media_manager "debrid_drive/media/manager"
	media_service "debrid_drive/media/service"
	"debrid_drive/poller"

	"github.com/sushydev/real_debrid_go"
	vfs "github.com/sushydev/vfs_go"
)

func main() {
	config.Validate()

	token := config.GetRealDebridToken()
	client := real_debrid_go.NewClient(token)

	database, err := database.NewInstance()
	if err != nil {
		panic(fmt.Sprintf("Failed to create database: %v", err))
	}

	fileSystem, err := vfs.NewFileSystem("debrid_drive", "./file_system.db")
	if err != nil {
		panic(fmt.Sprintf("Failed to create file system: %v", err))
	}

	mediaService := media_service.NewMediaService(database.GetDatabase())
	mediaManager := media_manager.NewMediaManager(client, database, fileSystem, mediaService)
	fileSystemServer := file_system_server.NewFileSystemServer(client, fileSystem, mediaManager)

	go func() {
		err := fileSystemServer.Serve()
		if err != nil {
			panic(fmt.Sprintf("Failed to create API: %v", err))
		}
	}()

	poller := poller.NewPoller(client, mediaManager)
	poller.Poll()
}
