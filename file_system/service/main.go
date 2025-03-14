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
	vfs_interfaces "github.com/sushydev/vfs_go/filesystem/interfaces"
)

var _ api.FileSystemServiceServer = &FileSystemService{}

type FileSystemService struct {
	api.UnimplementedFileSystemServiceServer

	client       *real_debrid.Client
	fileSystem   vfs_interfaces.FileSystem
	mediaManager *media_service.MediaService
}

func NewFileSystemService(client *real_debrid.Client, fileSystem vfs_interfaces.FileSystem, mediaService *media_service.MediaService) *FileSystemService {
	return &FileSystemService{
		client:       client,
		fileSystem:   fileSystem,
		mediaManager: mediaService,
	}
}

func getApiNode(node vfs_interfaces.Node) (*api.Node, error) {
	if node == nil {
		return nil, nil
	}

	switch node.GetMode() {
	case fs.ModeDir:
		return &api.Node{
			Identifier: node.GetId(),
			Name:       node.GetName(),
			Type:       api.NodeType_DIRECTORY,
		}, nil
	default:
		return &api.Node{
			Identifier: node.GetId(),
			Name:       node.GetName(),
			Type:       api.NodeType_FILE,
		}, nil
	}
}

func (service *FileSystemService) Root(ctx context.Context, req *api.RootRequest) (*api.RootResponse, error) {
	node, err := service.fileSystem.Root()
	if err != nil {
		return nil, err
	}

	response := &api.RootResponse{
		Root: &api.Node{
			Identifier: node.GetId(),
			Name:       node.GetName(),
			Type:       api.NodeType_DIRECTORY,
		},
	}

	return response, nil
}

func (service *FileSystemService) ReadDirAll(ctx context.Context, req *api.ReadDirAllRequest) (*api.ReadDirAllResponse, error) {
	nodes, err := service.fileSystem.ReadDir(req.Identifier)
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
	node, err := service.fileSystem.Lookup(req.Identifier, req.Name)
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

func (service *FileSystemService) Remove(ctx context.Context, req *api.RemoveRequest) (*api.RemoveResponse, error) {
	parentDirectory, err := service.fileSystem.Open(req.Identifier)
	if err != nil {
		return nil, err
	}

	node, err := service.fileSystem.FindChildNode(req.Name, parentDirectory)
	if err != nil {
		return nil, err
	}

	if node == nil {
		return nil, nil
	}

	switch node.GetType() {
	case vfs_node.DirectoryNode:
		directory, err := service.fileSystem.GetDirectory(node.GetIdentifier())
		if err != nil {
			return nil, err
		}

		err = service.fileSystem.DeleteDirectory(directory)
		if err != nil {
			return nil, err
		}
	case vfs_node.FileNode:
		file, err := service.fileSystem.GetFile(node.GetIdentifier())
		if err != nil {
			return nil, err
		}

		torrentFile, err := service.mediaManager.GetTorrentFileByFile(file)
		if err != nil {
			return nil, err
		}

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
		} else {
			err = service.fileSystem.DeleteFile(file)
			if err != nil {
				return nil, err
			}
		}
	}

	return &api.RemoveResponse{}, nil
}

func (service *FileSystemService) Rename(ctx context.Context, req *api.RenameRequest) (*api.RenameResponse, error) {
	directory, err := service.fileSystem.GetDirectory(req.ParentIdentifier)
	if err != nil {
		return nil, err
	}

	node, err := service.fileSystem.FindChildNode(req.Name, directory)
	if err != nil {
		return nil, err
	}

	if node == nil {
		return nil, nil
	}

	newParent, err := service.fileSystem.GetDirectory(req.NewParentIdentifier)
	if err != nil {
		return nil, err
	}

	switch node.GetType() {
	case vfs_node.DirectoryNode:
		directory, err := service.fileSystem.GetDirectory(node.GetIdentifier())
		if err != nil {
			return nil, err
		}

		updatedDirectory, err := service.fileSystem.UpdateDirectory(directory, req.NewName, newParent)
		if err != nil {
			return nil, err
		}

		return &api.RenameResponse{
			Node: &api.Node{
				Identifier: updatedDirectory.GetIdentifier(),
				Name:       updatedDirectory.GetName(),
				Type:       api.NodeType_DIRECTORY,
			},
		}, nil
	case vfs_node.FileNode:
		file, err := service.fileSystem.GetFile(node.GetIdentifier())
		if err != nil {
			return nil, err
		}

		updatedFile, err := service.fileSystem.UpdateFile(file, req.NewName, newParent, file.GetContentType(), file.GetData())
		if err != nil {
			return nil, err
		}

		return &api.RenameResponse{
			Node: &api.Node{
				Identifier: updatedFile.GetIdentifier(),
				Name:       updatedFile.GetName(),
				Type:       api.NodeType_FILE,
			},
		}, nil
	}

	return nil, nil
}

func (service *FileSystemService) Create(ctx context.Context, req *api.CreateRequest) (*api.CreateResponse, error) {
	return nil, nil
}

func (service *FileSystemService) Mkdir(ctx context.Context, req *api.MkdirRequest) (*api.MkdirResponse, error) {
	parentNode, err := service.fileSystem.Open(req.ParentIdentifier)
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

	directory, err := service.fileSystem.GetNodeByParentAndName(parentNode.GetId(), req.Name)
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
			Identifier: file.GetIdentifier(),
			Name:       file.GetName(),
			Type:       api.NodeType_FILE,
		},
	}, nil
}

func (service *FileSystemService) GetVideoSize(ctx context.Context, req *api.GetVideoSizeRequest) (*api.GetVideoSizeResponse, error) {
	file, err := service.fileSystem.GetFile(req.Identifier)
	if err != nil {
		return nil, err
	}

	if file == nil {
		return nil, nil
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

	return &api.GetVideoSizeResponse{
		Size: uint64(torrentFile.GetSize()),
	}, nil
}

func (service *FileSystemService) GetVideoUrl(ctx context.Context, req *api.GetVideoUrlRequest) (*api.GetVideoUrlResponse, error) {
	file, err := service.fileSystem.GetFile(req.Identifier)
	if err != nil {
		return nil, err
	}

	if file == nil {
		return nil, nil
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

	response := &api.GetVideoUrlResponse{
		Url: unrestrictResponse.Download,
	}

	return response, nil
}
