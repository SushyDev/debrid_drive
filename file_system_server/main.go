package file_system_server

import (
	"fmt"
	"log"
	"net"

	"debrid_drive/config"
	"debrid_drive/vfs_api"

	media_manager "debrid_drive/media/manager"

	real_debrid "github.com/sushydev/real_debrid_go"
	vfs "github.com/sushydev/vfs_go"
	grpc "google.golang.org/grpc"
)

type FileSystemServer struct {
	server *grpc.Server
}

func NewFileSystemServer(client *real_debrid.Client, fileSystem *vfs.FileSystem, mediaManager *media_manager.MediaManager) *FileSystemServer {
	server := grpc.NewServer()

	fileSystemService := &FileSystemService{
		client:       client,
		fileSystem:   fileSystem,
		mediaManager: mediaManager,
	}

	vfs_api.RegisterFileSystemServiceServer(server, fileSystemService)

	fsServer := &FileSystemServer{
		server: server,
	}

	return fsServer
}

func (server *FileSystemServer) Serve() error {
	port := config.GetPort()
	listener, err := net.Listen("tcp", fmt.Sprintf(":%d", port))
	if err != nil {
		return fileSystemServerError("failed to listen", err)
	}

	log.Printf("Serving on port %d", port)

	return server.server.Serve(listener)
}

func fileSystemServerError(message string, err error) error {
	if err == nil {
		return nil
	}

	return fmt.Errorf("%s\n%w", message, err)
}
