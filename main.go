package main

import (
	"net/http"
	"time"

	"debrid_drive/config"
	"debrid_drive/database"
	filesystem_server "debrid_drive/filesystem/server"
	"debrid_drive/logger"
	media_repository "debrid_drive/media/repository"
	media_service "debrid_drive/media/service"
	"debrid_drive/poller"
	"debrid_drive/poller/action"

	"github.com/sushydev/real_debrid_go"
	filesystem "github.com/sushydev/vfs_go"
)

func main() {
	config.Validate()

	logger, err := logger.NewLogger("Main")
	if err != nil {
		panic(err)
	}

	logger.Info("Starting...")
	logger.Info("Using Poll URL: " + config.GetPollUrl())

	token := config.GetRealDebridToken()
	client := real_debrid_go.NewClient(token, &http.Client{})

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
	pollInterval := time.Duration(config.GetPollIntervalSeconds()) * time.Second
	poller := poller.New(pollUrl, "table", pollInterval, func([32]byte) {
		actioner.Poll()
	})

	poller.Start()
}
