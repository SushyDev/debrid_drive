package file_system_server

import (
	context "context"
	"fmt"

	"debrid_drive/config"
	"debrid_drive/vfs_api"

	media_service "debrid_drive/media/service"

	real_debrid "github.com/sushydev/real_debrid_go"
	real_debrid_api "github.com/sushydev/real_debrid_go/api"
	vfs "github.com/sushydev/vfs_go"
	vfs_node "github.com/sushydev/vfs_go/node"
)

var _ vfs_api.FileSystemServiceServer = &FileSystemService{}

type FileSystemService struct {
	vfs_api.UnimplementedFileSystemServiceServer

	client       *real_debrid.Client
	fileSystem   *vfs.FileSystem
	mediaManager *media_service.MediaService
}

func NewFileSystemService(client *real_debrid.Client, fileSystem *vfs.FileSystem, mediaService *media_service.MediaService) *FileSystemService {
	return &FileSystemService{
		client:       client,
		fileSystem:   fileSystem,
		mediaManager: mediaService,
	}
}

// fvs_node to vfs_api node
// TODO: better name
func nodeToNode(node *vfs_node.Node) (*vfs_api.Node, error) {
	if node == nil {
		return nil, fmt.Errorf("node is nil")
	}

	switch node.GetType() {
	case vfs_node.DirectoryNode:
		return &vfs_api.Node{
			Identifier: node.GetIdentifier(),
			Name:       node.GetName(),
			Type:       vfs_api.NodeType_DIRECTORY,
		}, nil
	case vfs_node.FileNode:
		return &vfs_api.Node{
			Identifier: node.GetIdentifier(),
			Name:       node.GetName(),
			Type:       vfs_api.NodeType_FILE,
		}, nil
	}

	return nil, fmt.Errorf("unknown node type")
}

func (service *FileSystemService) Root(ctx context.Context, req *vfs_api.RootRequest) (*vfs_api.RootResponse, error) {
	root := service.fileSystem.GetRoot()

	response := &vfs_api.RootResponse{
		Root: &vfs_api.Node{
			Identifier: root.GetIdentifier(),
			Name:       root.GetName(),
			Type:       vfs_api.NodeType_DIRECTORY,
		},
	}

	return response, nil
}

func (service *FileSystemService) ReadDirAll(ctx context.Context, req *vfs_api.ReadDirAllRequest) (*vfs_api.ReadDirAllResponse, error) {
	directory, err := service.fileSystem.GetDirectory(req.Identifier)
	if err != nil {
		return nil, err
	}

	nodes, err := service.fileSystem.GetChildNodes(directory)
	if err != nil {
		return nil, err
	}

	var responseNodes []*vfs_api.Node

	for _, node := range nodes {
		apiNode, err := nodeToNode(node)
		if err != nil {
			continue
		}

		if apiNode == nil {
			continue
		}

		responseNodes = append(responseNodes, apiNode)
	}

	return &vfs_api.ReadDirAllResponse{
		Nodes: responseNodes,
	}, nil

}

func (service *FileSystemService) Lookup(ctx context.Context, req *vfs_api.LookupRequest) (*vfs_api.LookupResponse, error) {
	parent, err := service.fileSystem.GetDirectory(req.Identifier)
	if err != nil {
		return nil, err
	}

	node, err := service.fileSystem.FindChildNode(req.Name, parent)
	if err != nil {
		return nil, err
	}

	usableNode, err := nodeToNode(node)
	if err != nil {
		return nil, err
	}

	response := &vfs_api.LookupResponse{
		Node: usableNode,
	}

	return response, nil
}

func (service *FileSystemService) Remove(ctx context.Context, req *vfs_api.RemoveRequest) (*vfs_api.RemoveResponse, error) {
	parentDirectory, err := service.fileSystem.GetDirectory(req.Identifier)
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

	return &vfs_api.RemoveResponse{}, nil
}

func (service *FileSystemService) Rename(ctx context.Context, req *vfs_api.RenameRequest) (*vfs_api.RenameResponse, error) {
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

		return &vfs_api.RenameResponse{
			Node: &vfs_api.Node{
				Identifier: updatedDirectory.GetIdentifier(),
				Name:       updatedDirectory.GetName(),
				Type:       vfs_api.NodeType_DIRECTORY,
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

		return &vfs_api.RenameResponse{
			Node: &vfs_api.Node{
				Identifier: updatedFile.GetIdentifier(),
				Name:       updatedFile.GetName(),
				Type:       vfs_api.NodeType_FILE,
			},
		}, nil
	}

	return nil, nil
}

func (service *FileSystemService) Create(ctx context.Context, req *vfs_api.CreateRequest) (*vfs_api.CreateResponse, error) {
	return nil, nil
}

func (service *FileSystemService) Mkdir(ctx context.Context, req *vfs_api.MkdirRequest) (*vfs_api.MkdirResponse, error) {
	parent, err := service.fileSystem.GetDirectory(req.ParentIdentifier)
	if err != nil {
		return nil, err
	}

	directory, err := service.fileSystem.CreateDirectory(req.Name, parent)
	if err != nil {
		return nil, err
	}

	return &vfs_api.MkdirResponse{
		Node: &vfs_api.Node{
			Identifier: directory.GetIdentifier(),
			Name:       directory.GetName(),
			Type:       vfs_api.NodeType_DIRECTORY,
		},
	}, nil
}

func (service *FileSystemService) Link(ctx context.Context, req *vfs_api.LinkRequest) (*vfs_api.LinkResponse, error) {
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

	return &vfs_api.LinkResponse{
		Node: &vfs_api.Node{
			Identifier: file.GetIdentifier(),
			Name:       file.GetName(),
			Type:       vfs_api.NodeType_FILE,
		},
	}, nil
}

func (service *FileSystemService) GetVideoSize(ctx context.Context, req *vfs_api.GetVideoSizeRequest) (*vfs_api.GetVideoSizeResponse, error) {
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

	return &vfs_api.GetVideoSizeResponse{
		Size: uint64(torrentFile.GetSize()),
	}, nil
}

func (service *FileSystemService) GetVideoUrl(ctx context.Context, req *vfs_api.GetVideoUrlRequest) (*vfs_api.GetVideoUrlResponse, error) {
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

	response := &vfs_api.GetVideoUrlResponse{
		Url: unrestrictResponse.Download,
	}

	return response, nil
}
