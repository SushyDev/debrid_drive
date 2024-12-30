package server

import (
	"fmt"
	"net"

	"debrid_drive/config"
	"debrid_drive/logger"
	"debrid_drive/vfs_api"

	media_manager "debrid_drive/media/manager"
	file_system_service "debrid_drive/file_system/service"

	real_debrid "github.com/sushydev/real_debrid_go"
	vfs "github.com/sushydev/vfs_go"
	grpc "google.golang.org/grpc"
)

type FileSystemServer struct {
	server *grpc.Server
	logger *logger.Logger
}

func NewFileSystemServer(client *real_debrid.Client, fileSystem *vfs.FileSystem, mediaManager *media_manager.MediaManager) *FileSystemServer {
	logger, err := logger.NewLogger("File System Server")
	if err != nil {
		panic(err)
	}

	server := grpc.NewServer()

	fileSystemService := file_system_service.NewFileSystemService(client, fileSystem, mediaManager)

	vfs_api.RegisterFileSystemServiceServer(server, fileSystemService)

	fileSystemServer := &FileSystemServer{
		server: server,
		logger: logger,
	}

	return fileSystemServer
}

func (server *FileSystemServer) Serve()  {
	port := config.GetPort()

	listener, err := net.Listen("tcp", fmt.Sprintf(":%d", port))
	if err != nil {
		server.error("failed to listen", err)
		return
	}

	server.info(fmt.Sprintf("Listening on port %d", port))

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
