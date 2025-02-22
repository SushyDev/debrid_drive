package main

import (
	"debrid_drive/config"
	"debrid_drive/database"
	"debrid_drive/logger"
	file_system_server "debrid_drive/file_system/server"
	media_service "debrid_drive/media/service"
	media_repository "debrid_drive/media/repository"
	"debrid_drive/poller"
	"debrid_drive/garbage_cleaner"

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

	mediaService := media_repository.NewMediaService(database.GetDatabase())
	mediaManager := media_service.NewMediaService(client, database, fileSystem, mediaService)
	fileSystemServer := file_system_server.NewFileSystemServer(client, fileSystem, mediaManager)

	fileSystemServerReady := make(chan struct{})
	go fileSystemServer.Serve(fileSystemServerReady)
	<-fileSystemServerReady

	// Init garbage cleaner
	garbageCleaner := garbage_cleaner.NewGarbageCleaner(fileSystem)
	garbageCleaner.Poll()
	go garbageCleaner.Cron()

	// Init poller
	poller := poller.NewPoller(client, mediaManager)
	poller.Poll()
	poller.Cron()
}
