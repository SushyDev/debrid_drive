package main

import (
	"debrid_drive/config"
	"debrid_drive/database"
	"debrid_drive/logger"
	file_system_server "debrid_drive/file_system/server"
	media_manager "debrid_drive/media/manager"
	media_service "debrid_drive/media/service"
	"debrid_drive/poller"

	"github.com/sushydev/real_debrid_go"
	vfs "github.com/sushydev/vfs_go"
)

func main() {
	config.Validate()

	logger, err := logger.NewLogger("Main")
	if err != nil {
		panic(err)
	}

	logger.Info("Starting...")

	token := config.GetRealDebridToken()
	client := real_debrid_go.NewClient(token)

	database, err := database.NewInstance()
	if err != nil {
		logger.Error("Failed to create database", err)
		panic(err)
	}

	fileSystem, err := vfs.NewFileSystem("debrid_drive", "./filesystem.db")
	if err != nil {
		logger.Error("Failed to create file system", err)
		panic(err)
	}

	mediaService := media_service.NewMediaService(database.GetDatabase())
	mediaManager := media_manager.NewMediaManager(client, database, fileSystem, mediaService)
	fileSystemServer := file_system_server.NewFileSystemServer(client, fileSystem, mediaManager)

	go fileSystemServer.Serve()

	poller := poller.NewPoller(client, mediaManager)
	poller.Poll()
}
