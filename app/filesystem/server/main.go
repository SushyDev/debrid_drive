package server

import (
	"fmt"
	"net"

	"debrid_drive/config"
	"debrid_drive/logger"
	api "github.com/sushydev/stream_mount_api"

	filesystem_service "debrid_drive/filesystem/service"
	media_service "debrid_drive/media/service"

	real_debrid "github.com/sushydev/real_debrid_go"
	"github.com/sushydev/vfs_go"
	grpc "google.golang.org/grpc"
)

type FileSystemServer struct {
	server *grpc.Server
	logger *logger.Logger
}

func NewFileSystemServer(client *real_debrid.Client, fileSystem *filesystem.FileSystem, mediaService *media_service.MediaService) *FileSystemServer {
	logger, err := logger.NewLogger("File System Server")
	if err != nil {
		panic(err)
	}

	server := grpc.NewServer()

	fileSystemService := filesystem_service.NewFileSystemService(client, fileSystem, mediaService)

	api.RegisterFileSystemServiceServer(server, fileSystemService)

	fileSystemServer := &FileSystemServer{
		server: server,
		logger: logger,
	}

	return fileSystemServer
}

func (server *FileSystemServer) Serve(ready chan struct{}) {
	port := config.GetPort()

	listener, err := net.Listen("tcp", fmt.Sprintf(":%d", port))
	if err != nil {
		server.error("failed to listen", err)
		return
	}

	server.info(fmt.Sprintf("Listening on port %d", port))
	close(ready)

	err = server.server.Serve(listener)
	if err != nil {
		server.error("failed to serve", err)
	}
}

func (server *FileSystemServer) info(message string) {
	server.logger.Info(message)
}

func (server *FileSystemServer) error(message string, err error) {
	server.logger.Error(message, err)
}
