package main

import (
	"net/http"
	"time"

	"debrid_drive/config"
	"debrid_drive/database"
	"debrid_drive/logger"
	media_repository "debrid_drive/media/repository"
	media_service "debrid_drive/media/service"
	filesystem_server "debrid_drive/filesystem/server"
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

	token := config.GetRealDebridToken()
	client := real_debrid_go.NewClient(token, &http.Client{})

	logger.Info("Initializing media database...")
	database, err := database.NewInstance()
	if err != nil {
		logger.Error("Failed to create media database", err)
		return
	}

	logger.Info("Initializing file system database...")
	fileSystem, err := filesystem.New("app_data/filesystem.db")
	if err != nil {
		logger.Error("Failed to create file system database", err)
		return
	}

	mediaRepository := media_repository.NewMediaService(database.GetDatabase())
	mediaService := media_service.NewMediaService(client, database, fileSystem, mediaRepository)
	fileSystemServer := filesystem_server.NewFileSystemServer(client, fileSystem, mediaService)

	startPollers(client, mediaRepository, mediaService, fileSystem, logger)

	logger.Info("Starting file system server...")
	fileSystemServerReady := make(chan struct{})
	go fileSystemServer.Serve(fileSystemServerReady)
	<-fileSystemServerReady
	logger.Info("File system server is ready")

	select {} // Block forever, or until a signal is received to stop the application
}

func startPollers(
	client *real_debrid_go.Client,
	mediaRepository *media_repository.MediaRepository,
	mediaService *media_service.MediaService,
	fileSystem *filesystem.FileSystem,
	logger *logger.Logger,
) {
	logger.Info("Initializing actioner...")
	actioner := action.New(client, mediaRepository, mediaService, fileSystem)

	logger.Info("Running actioner for sync")
	actioner.Poll()

	logger.Info("Initializing pollers")
	pollUrl := config.GetPollUrl()
	pollInterval := config.GetPollIntervalSeconds()

	logger.Info("Initializing change poller with interval: " + pollInterval.String())
	changePoller := poller.NewChangePoller(pollUrl, "table", pollInterval, func([32]byte) {
		actioner.Poll()
	})

	logger.Info("Initializing time poller with interval: " + time.Duration(10*time.Minute).String())
	timePoller := poller.NewTimePoller(10*time.Minute, func() {
		actioner.Poll()
	})

	go changePoller.Start()
	go timePoller.Start()

	logger.Info("Pollers started, waiting for changes...")
}
