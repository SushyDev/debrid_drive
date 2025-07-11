package main

import (
	"time"

	"debrid_drive/config"
	"debrid_drive/database"
	"debrid_drive/logger"
	filesystem_server "debrid_drive/filesystem/server"
	media_service "debrid_drive/media/service"
	media_repository "debrid_drive/media/repository"
	"debrid_drive/poller"
	"debrid_drive/poller/action"

	"github.com/sushydev/real_debrid_go"
	"github.com/sushydev/vfs_go"
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

	fileSystem, err := filesystem.New("app_data/filesystem.db")
	if err != nil {
		logger.Error("Failed to create file system", err)
		panic(err)
	}

	mediaService := media_repository.NewMediaService(database.GetDatabase())
	mediaManager := media_service.NewMediaService(client, database, fileSystem, mediaService)
	fileSystemServer := filesystem_server.NewFileSystemServer(client, fileSystem, mediaManager)

	fileSystemServerReady := make(chan struct{})
	go fileSystemServer.Serve(fileSystemServerReady)
	<-fileSystemServerReady

	// Init actioner
	actioner := action.New(client, mediaService, mediaManager, fileSystem)

	// Init new poller
	pollUrl := config.GetPollUrl()
	poller := poller.New(pollUrl, "table", 5*time.Second, func([32]byte) {
		actioner.Poll()
	})

	poller.Start()
}
