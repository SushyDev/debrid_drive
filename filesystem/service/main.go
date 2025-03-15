package file_system_server

import (
	"context"
	"database/sql"
	"fmt"
	"io/fs"
	"syscall"

	api "github.com/sushydev/stream_mount_api"

	media_service "debrid_drive/media/service"

	real_debrid "github.com/sushydev/real_debrid_go"
	real_debrid_api "github.com/sushydev/real_debrid_go/api"

	"github.com/sushydev/vfs_go"
	filesystem_interfaces "github.com/sushydev/vfs_go/interfaces"
	filesystem_service "github.com/sushydev/vfs_go/service"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

var _ api.FileSystemServiceServer = &FileSystemService{}

type FileSystemService struct {
	api.UnimplementedFileSystemServiceServer

	client       *real_debrid.Client
	fileSystem   *filesystem.FileSystem
	mediaManager *media_service.MediaService
}

func NewFileSystemService(client *real_debrid.Client, fileSystem *filesystem.FileSystem, mediaService *media_service.MediaService) *FileSystemService {
	return &FileSystemService{
		client:       client,
		fileSystem:   fileSystem,
		mediaManager: mediaService,
	}
}

func (service *FileSystemService) isStreamable(node filesystem_interfaces.Node) bool {
	if node == nil {
		return false
	}

	switch node.GetMode() {
	case fs.ModeDir:
		return false
	case fs.ModeSymlink:
		// TODO: Get source node and check if it's streamable
		return false
	case fs.FileMode(0):
		torrentFile, err := service.mediaManager.GetTorrentFileByFile(node)
		if err != nil && err != sql.ErrNoRows {
			return false
		}

		return torrentFile != nil
	default:
		return false
	}
}

func (service *FileSystemService) getApiNode(node filesystem_interfaces.Node) (*api.Node, error) {
	if node == nil {
		return nil, nil
	}

	switch node.GetMode() {
	case fs.ModeDir:
		return &api.Node{
			Id:         node.GetId(),
			Name:       node.GetName(),
			Mode:       uint32(node.GetMode()),
			Streamable: false,
		}, nil
	case fs.FileMode(0):
		return &api.Node{
			Id:         node.GetId(),
			Name:       node.GetName(),
			Mode:       uint32(node.GetMode()),
			Streamable: service.isStreamable(node),
		}, nil
	case fs.ModeSymlink:
		return &api.Node{
			Id:         node.GetId(),
			Name:       node.GetName(),
			Mode:       uint32(node.GetMode()),
			Streamable: service.isStreamable(node),
		}, nil
	default:
		return nil, nil
	}
}

func (service *FileSystemService) Root(ctx context.Context, req *api.RootRequest) (*api.RootResponse, error) {
	node, err := filesystem_service.GetRoot(service.fileSystem)
	if err == syscall.ENOENT {
		return nil, status.Error(codes.NotFound, "node not found")
	}

	if err != nil {
		return nil, err
	}

	apiNode, err := service.getApiNode(node)
	if err != nil {
		return nil, err
	}

	return &api.RootResponse{
		Root: apiNode,
	}, nil
}

func (service *FileSystemService) ReadDirAll(ctx context.Context, req *api.ReadDirAllRequest) (*api.ReadDirAllResponse, error) {
	nodes, err := service.fileSystem.ReadDir(req.NodeId)
	if err == syscall.ENOENT {
		return nil, status.Error(codes.NotFound, "node not found")
	}

	if err != nil {
		return nil, err
	}

	var responseNodes []*api.Node

	for _, node := range nodes {
		apiNode, err := service.getApiNode(node)
		if err != nil {
			continue
		}

		if apiNode == nil {
			continue
		}

		responseNodes = append(responseNodes, apiNode)
	}

	return &api.ReadDirAllResponse{
		Nodes: responseNodes,
	}, nil

}

func (service *FileSystemService) Lookup(ctx context.Context, req *api.LookupRequest) (*api.LookupResponse, error) {
	node, err := service.fileSystem.Lookup(req.NodeId, req.Name)
	if err == syscall.ENOENT {
		return nil, status.Error(codes.NotFound, "node not found")
	}

	if err != nil {
		return nil, err
	}

	apiNode, err := service.getApiNode(node)
	if err != nil {
		return nil, err
	}

	response := &api.LookupResponse{
		Node: apiNode,
	}

	return response, nil
}

func (service *FileSystemService) Create(ctx context.Context, req *api.CreateRequest) (*api.CreateResponse, error) {
	parentDirectory, err := service.fileSystem.Open(req.ParentNodeId)
	if err != nil {
		return nil, err
	}

	if parentDirectory == nil {
		return nil, syscall.ENOENT
	}

	if !parentDirectory.GetMode().IsDir() {
		return nil, syscall.ENOTDIR
	}

	err = service.fileSystem.Touch(parentDirectory.GetId(), req.Name)
	if err != nil {
		return nil, err
	}

	return &api.CreateResponse{}, nil
}

// remove file
func (service *FileSystemService) Remove(ctx context.Context, req *api.RemoveRequest) (*api.RemoveResponse, error) {
	node, err := service.fileSystem.Lookup(req.ParentNodeId, req.Name)
	if err != nil {
		return nil, err
	}

	if node == nil {
		return nil, nil
	}

	switch node.GetMode() {
	case fs.FileMode(0):
		file, err := service.fileSystem.Open(node.GetId())
		if err != nil {
			return nil, err
		}

		if file == nil {
			return nil, nil
		}

		if !file.GetMode().IsRegular() {
			return nil, syscall.EISDIR
		}

		torrentFile, err := service.mediaManager.GetTorrentFileByFile(file)
		if err != nil && err != sql.ErrNoRows {
			fmt.Printf("Failed to get torrent file by file: %v\n", err)
			return nil, err
		}

		if torrentFile != nil {
			torrent, err := service.mediaManager.GetTorrentByTorrentFile(torrentFile)
			if err != nil {
				fmt.Printf("Failed to get torrent by torrent file: %v\n", err)
				return nil, err
			}

			if torrent != nil {
				transaction, err := service.mediaManager.NewTransaction()
				if err != nil {
					fmt.Printf("Failed to create transaction: %v\n", err)
					return nil, err
				}

				err = service.mediaManager.DeleteTorrent(transaction, torrent)
				if err != nil {
					fmt.Printf("Failed to delete torrent: %v\n", err)
					return nil, err
				}

				err = transaction.Commit()
				if err != nil {
					fmt.Printf("Failed to commit transaction: %v\n", err)
					return nil, err
				}
			}
		}

		err = service.fileSystem.RemoveFile(file.GetId())
		if err != nil {
			fmt.Printf("Failed to remove file: %v\n", err)
			return nil, err
		}

	case fs.ModeDir:
		directory, err := service.fileSystem.Open(node.GetId())
		if err != nil {
			return nil, err
		}

		if directory == nil {
			return nil, nil
		}

		if !directory.GetMode().IsDir() {
			return nil, syscall.ENOTDIR
		}

		err = service.fileSystem.RmDir(directory.GetId())
		if err != nil {
			return nil, err
		}
	}

	return &api.RemoveResponse{}, nil
}

func (service *FileSystemService) Rename(ctx context.Context, req *api.RenameRequest) (*api.RenameResponse, error) {
	node, err := service.fileSystem.Lookup(req.OldParentNodeId, req.OldName)
	if err != nil {
		return nil, err
	}

	if node == nil {
		return nil, syscall.ENOENT
	}

	if service.isStreamable(node) {
		fmt.Printf("TORRENT RENAME")

		err := service.fileSystem.Rename(node.GetId(), req.NewName, req.NewParentNodeId)
		if err != nil {
			return nil, err
		}

		updatedDirectory, err := service.fileSystem.Open(node.GetId())
		if err != nil {
			return nil, err
		}

		apiNode, err := service.getApiNode(updatedDirectory)
		if err != nil {
			return nil, err
		}

		return &api.RenameResponse{
			Node: apiNode,
		}, nil
	} else {
		fmt.Printf("REGULAR RENAME", req.OldParentNodeId, req.OldName, req.NewName, req.NewParentNodeId)

		err := service.fileSystem.Rename(node.GetId(), req.NewName, req.NewParentNodeId)
		if err != nil {
			return nil, err
		}

		newNode, err := service.fileSystem.Open(node.GetId())
		if err != nil {
			return nil, err
		}

		apiNode, err := service.getApiNode(newNode)
		if err != nil {
			return nil, err
		}

		return &api.RenameResponse{
			Node: apiNode,
		}, nil
	}
}

func (service *FileSystemService) Mkdir(ctx context.Context, req *api.MkdirRequest) (*api.MkdirResponse, error) {
	parentNode, err := service.fileSystem.Open(req.ParentNodeId)
	if err != nil {
		return nil, err
	}

	if parentNode == nil {
		return nil, syscall.ENOENT
	}

	if !parentNode.GetMode().IsDir() {
		return nil, syscall.ENOTDIR
	}

	err = service.fileSystem.MkDir(parentNode.GetId(), req.Name)
	if err != nil {
		return nil, err
	}

	directory, err := service.fileSystem.Lookup(parentNode.GetId(), req.Name)
	if err != nil {
		return nil, err
	}

	if directory == nil {
		return nil, syscall.ENOENT
	}

	if !directory.GetMode().IsDir() {
		return nil, syscall.ENOTDIR
	}

	apiNode, err := service.getApiNode(directory)
	if err != nil {
		return nil, err
	}

	return &api.MkdirResponse{
		Node: apiNode,
	}, nil
}

func (service *FileSystemService) Link(ctx context.Context, req *api.LinkRequest) (*api.LinkResponse, error) {
	err := service.fileSystem.Link(req.NodeId, req.Name, req.ParentNodeId)
	if err != nil {
		return nil, err
	}

	linkedNode, err := service.fileSystem.Lookup(req.ParentNodeId, req.Name)
	if err != nil {
		return nil, err
	}

	apiNode, err := service.getApiNode(linkedNode)
	if err != nil {
		return nil, err
	}

	return &api.LinkResponse{
		Node: apiNode,
	}, nil
}

func (service *FileSystemService) ReadFile(ctx context.Context, req *api.ReadFileRequest) (*api.ReadFileResponse, error) {
	node, err := service.fileSystem.Open(req.NodeId)
	if err != nil {
		return nil, err
	}

	if node.GetMode().IsDir() {
		return nil, syscall.EISDIR
	}

	if service.isStreamable(node) {
		return nil, nil
	}

	content, err := service.fileSystem.ReadFile(node.GetId())
	if err != nil {
		return nil, err
	}

	return &api.ReadFileResponse{
		Data: content[req.Offset:],
	}, nil
}

func (service *FileSystemService) WriteFile(ctx context.Context, req *api.WriteFileRequest) (*api.WriteFileResponse, error) {
	node, err := service.fileSystem.Open(req.NodeId)
	if err != nil {
		return nil, err
	}

	if node.GetMode().IsDir() {
		return nil, syscall.EISDIR
	}

	if service.isStreamable(node) {
		return nil, nil
	}

	content, err := service.fileSystem.ReadFile(node.GetId())

	content = append(content[:req.Offset], req.Data...)

	n, err := service.fileSystem.WriteFile(node.GetId(), content)
	if err != nil {
		return nil, err
	}

	return &api.WriteFileResponse{
		BytesWritten: uint64(n),
	}, nil
}

func (service *FileSystemService) ReadLink(ctx context.Context, req *api.ReadLinkRequest) (*api.ReadLinkResponse, error) {
	path, err := service.fileSystem.ReadLink(req.NodeId)
	if err != nil {
		return nil, err
	}

	return &api.ReadLinkResponse{
		Path: path,
	}, nil
}

func (service *FileSystemService) GetFileInfo(ctx context.Context, req *api.GetFileInfoRequest) (*api.GetFileInfoResponse, error) {
	file, err := service.fileSystem.Open(req.NodeId)
	if err != nil {
		return nil, err
	}

	if file == nil {
		return nil, nil
	}

	if !service.isStreamable(file) {
		return nil, nil
	}

	torrentFile, err := service.mediaManager.GetTorrentFileByFile(file)
	if err != nil && err != sql.ErrNoRows {
		return nil, err
	}

	if torrentFile == nil {
		return nil, nil
	}

	return &api.GetFileInfoResponse{
		Size: uint64(torrentFile.GetSize()),
		Mode: uint32(file.GetMode()),
	}, nil
}

func (service *FileSystemService) GetStreamUrl(ctx context.Context, req *api.GetStreamUrlRequest) (*api.GetStreamUrlResponse, error) {
	file, err := service.fileSystem.Open(req.NodeId)
	if err != nil {
		return nil, err
	}

	if file == nil {
		return nil, nil
	}

	if !service.isStreamable(file) {
		return nil, nil
	}

	torrentFile, err := service.mediaManager.GetTorrentFileByFile(file)
	if err != nil && err != sql.ErrNoRows {
		return nil, err
	}

	if torrentFile == nil {
		return nil, nil
	}

	unrestrictResponse, err := real_debrid_api.UnrestrictLink(service.client, torrentFile.GetLink())
	if err != nil {
		return nil, err
	}

	response := &api.GetStreamUrlResponse{
		Url: unrestrictResponse.Download,
	}

	return response, nil
}
