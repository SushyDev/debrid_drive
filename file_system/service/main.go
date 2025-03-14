package file_system_server

import (
	"context"
	"io/fs"
	"syscall"

	"debrid_drive/config"
	api "github.com/sushydev/stream_mount_api"

	media_service "debrid_drive/media/service"

	real_debrid "github.com/sushydev/real_debrid_go"
	real_debrid_api "github.com/sushydev/real_debrid_go/api"
	"github.com/sushydev/vfs_go/filesystem"
	filesystem_interfaces "github.com/sushydev/vfs_go/filesystem/interfaces"
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

func getApiNode(node filesystem_interfaces.Node) (*api.Node, error) {
	if node == nil {
		return nil, nil
	}

	switch node.GetMode() {
	case fs.ModeDir:
		return &api.Node{
			Id:   node.GetId(),
			Name: node.GetName(),
			Mode: uint32(node.GetMode()),
		}, nil
	default:
		return &api.Node{
			Id:   node.GetId(),
			Name: node.GetName(),
			Mode: uint32(node.GetMode()),
		}, nil
	}
}

func (service *FileSystemService) Root(ctx context.Context, req *api.RootRequest) (*api.RootResponse, error) {
	node, err := service.fileSystem.Root()
	if err != nil {
		return nil, err
	}

	apiNode, err := getApiNode(node)
	if err != nil {
		return nil, err
	}

	return &api.RootResponse{
		Root: apiNode,
	}, nil
}

func (service *FileSystemService) ReadDirAll(ctx context.Context, req *api.ReadDirAllRequest) (*api.ReadDirAllResponse, error) {
	nodes, err := service.fileSystem.ReadDir(req.NodeId)
	if err != nil {
		return nil, err
	}

	var responseNodes []*api.Node

	for _, node := range nodes {
		apiNode, err := getApiNode(node)
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
	if err != nil {
		return nil, err
	}

	apiNode, err := getApiNode(node)
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
	default:
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

		err = service.fileSystem.RemoveFile(file.GetId())
		if err != nil {
			return nil, err
		}

		torrentFile, err := service.mediaManager.GetTorrentFileByFile(file)
		if err != nil {
			return nil, err
		}

		if torrentFile != nil {
			torrent, err := service.mediaManager.GetTorrentByTorrentFile(torrentFile)
			if err != nil {
				return nil, err
			}

			if torrent != nil {
				transaction, err := service.mediaManager.NewTransaction()
				if err != nil {
					return nil, err
				}

				err = service.mediaManager.DeleteTorrent(transaction, torrent)
				if err != nil {
					return nil, err
				}

				err = transaction.Commit()
				if err != nil {
					return nil, err
				}
			}
		}
	}

	return &api.RemoveResponse{}, nil
}

func (service *FileSystemService) Rename(ctx context.Context, req *api.RenameRequest) (*api.RenameResponse, error) {
	node, err := service.fileSystem.Lookup(req.ParentNodeId, req.Name)
	if err != nil {
		return nil, err
	}

	if node == nil {
		return nil, nil
	}

	newParent, err := service.fileSystem.Open(req.NewParentNodeId)
	if err != nil {
		return nil, err
	}

	if newParent == nil {
		return nil, syscall.ENOENT
	}

	if !newParent.GetMode().IsDir() {
		return nil, syscall.ENOTDIR
	}

	switch node.GetMode() {
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

		updatedDirectory, err := service.fileSystem.UpdateDirectory(directory, req.NewName, newParent)
		if err != nil {
			return nil, err
		}

		apiNode, err := getApiNode(updatedDirectory)
		if err != nil {
			return nil, err
		}

		return &api.RenameResponse{
			Node: apiNode,
		}, nil
	default:
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

		updatedFile, err := service.fileSystem.UpdateFile(file, req.NewName, newParent, file.GetContentType(), file.GetData())
		if err != nil {
			return nil, err
		}

		apiNode, err := getApiNode(updatedFile)
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

	apiNode, err := getApiNode(directory)
	if err != nil {
		return nil, err
	}

	return &api.MkdirResponse{
		Node: apiNode,
	}, nil
}

func (service *FileSystemService) Link(ctx context.Context, req *api.LinkRequest) (*api.LinkResponse, error) {
	parent, err := service.fileSystem.GetDirectory(req.ParentIdentifier)
	if err != nil {
		return nil, err
	}

	existingFile, err := service.fileSystem.GetFile(req.Identifier)
	if err != nil {
		return nil, err
	}

	if existingFile == nil {
		return nil, nil
	}

	file, err := service.fileSystem.UpdateFile(existingFile, req.Name, parent, existingFile.GetContentType(), existingFile.GetData())

	return &api.LinkResponse{
		Node: &api.Node{
			Id:   file.GetId(),
			Name: file.GetName(),
			Mode: uint32(file.GetMode()),
		},
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

	if !file.GetMode().IsRegular() {
		return nil, syscall.EISDIR
	}

	if file.GetContentType() != config.GetContentType() {
		return nil, nil
	}

	torrentFile, err := service.mediaManager.GetTorrentFileByFile(file)
	if err != nil {
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

	if !file.GetMode().IsRegular() {
		return nil, syscall.EISDIR
	}

	if file.GetContentType() != config.GetContentType() {
		return nil, nil
	}

	torrentFile, err := service.mediaManager.GetTorrentFileByFile(file)
	if err != nil {
		return nil, err
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
