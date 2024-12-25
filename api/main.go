package api

import (
	context "context"
	"log"
	"net"

	"debrid_drive/vfs_api"

	"debrid_drive/torrent_manager"
	real_debrid "github.com/sushydev/real_debrid_go"
	real_debrid_api "github.com/sushydev/real_debrid_go/api"
	vfs "github.com/sushydev/vfs_go"
	vfs_node "github.com/sushydev/vfs_go/node"
	grpc "google.golang.org/grpc"
)

type FileSystemService struct {
	vfs_api.UnimplementedFileSystemServiceServer

	client         *real_debrid.Client
	fileSystem     *vfs.FileSystem
	torrentManager *torrent_manager.Instance
}

func NewApi(client *real_debrid.Client, fileSystem *vfs.FileSystem, torrentManager *torrent_manager.Instance) error {
	listener, err := net.Listen("tcp", ":6969")
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	server := grpc.NewServer()
	fileSystemService := &FileSystemService{
		client:         client,
		fileSystem:     fileSystem,
		torrentManager: torrentManager,
	}

	vfs_api.RegisterFileSystemServiceServer(server, fileSystemService)

	return server.Serve(listener)
}

func (service *FileSystemService) Root(ctx context.Context, req *vfs_api.RootRequest) (*vfs_api.RootResponse, error) {
	root := service.fileSystem.GetRoot()

	return &vfs_api.RootResponse{
		Root: &vfs_api.Node{
			Identifier: root.GetIdentifier(),
			Name:       root.GetName(),
			Type:       vfs_api.NodeType_DIRECTORY,
		},
	}, nil
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
		switch node.GetType() {
		case vfs_node.DirectoryNode:
			directory := &vfs_api.Node{
				Identifier: node.GetIdentifier(),
				Name:       node.GetName(),
				Type:       vfs_api.NodeType_DIRECTORY,
			}

			responseNodes = append(responseNodes, directory)
		case vfs_node.FileNode:
			file := &vfs_api.Node{
				Identifier: node.GetIdentifier(),
				Name:       node.GetName(),
				Type:       vfs_api.NodeType_FILE,
			}

			responseNodes = append(responseNodes, file)
		}
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

	if node == nil {
		return nil, nil
	}

	switch node.GetType() {
	case vfs_node.DirectoryNode:
		return &vfs_api.LookupResponse{
			Node: &vfs_api.Node{
				Identifier: node.GetIdentifier(),
				Name:       node.GetName(),
				Type:       vfs_api.NodeType_DIRECTORY,
			},
		}, nil
	case vfs_node.FileNode:
		return &vfs_api.LookupResponse{
			Node: &vfs_api.Node{
				Identifier: node.GetIdentifier(),
				Name:       node.GetName(),
				Type:       vfs_api.NodeType_FILE,
			},
		}, nil
	}

	return nil, nil
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

		torrentFile, err := service.torrentManager.GetTorrentFileByFile(file)
		if err != nil {
			return nil, err
		}

		torrent, err := service.torrentManager.GetTorrentByTorrentFile(torrentFile)
		if err != nil {
			return nil, err
		}

		if torrent != nil {
			transaction, err := service.torrentManager.NewTransaction()
			if err != nil {
				return nil, err
			}

			err = service.torrentManager.DeleteTorrent(transaction, torrent)
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

func afterFunc(node *vfs_node.Node) {
	log.Printf("Deleted %v\n", node.GetName())
}

// function delete recursive
// takes in directory id, callback for each file delete and callback for each directory delete
// this way in the callback for file delete i can check if there is a torrent linked to it and delete it

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
		log.Printf("File not found %v\n", req)
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

	if file.GetContentType() != "application/debrid-drive" {
		return nil, nil
	}

	torrentFile, err := service.torrentManager.GetTorrentFileByFile(file)
	if err != nil {
		return nil, err
	}

	if torrentFile == nil {
		return nil, nil
	}

	log.Printf("Getting video size for %v\n", torrentFile)

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

	if file.GetContentType() != "application/debrid-drive" {
		return nil, nil
	}

	torrentFile, err := service.torrentManager.GetTorrentFileByFile(file)
	if err != nil {
		return nil, err
	}

	response, err := real_debrid_api.UnrestrictLink(service.client, torrentFile.GetLink())
	if err != nil {
		return nil, err
	}

	return &vfs_api.GetVideoUrlResponse{
		Url: response.Download,
	}, nil
}
