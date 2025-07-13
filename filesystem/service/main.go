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

	filesystem "github.com/sushydev/vfs_go"
	filesystem_interfaces "github.com/sushydev/vfs_go/interfaces"
	filesystem_service "github.com/sushydev/vfs_go/service"
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

func (service *FileSystemService) getApiNode(node filesystem_interfaces.Node) *api.Node {
	if node == nil {
		return nil
	}

	switch node.GetMode() {
	case fs.ModeDir:
		return &api.Node{
			Id:         node.GetId(),
			Name:       node.GetName(),
			Mode:       uint32(node.GetMode()),
			Streamable: false,
		}
	case fs.FileMode(0):
		return &api.Node{
			Id:         node.GetId(),
			Name:       node.GetName(),
			Mode:       uint32(node.GetMode()),
			Streamable: service.isStreamable(node),
		}
	case fs.ModeSymlink:
		return &api.Node{
			Id:         node.GetId(),
			Name:       node.GetName(),
			Mode:       uint32(node.GetMode()),
			Streamable: service.isStreamable(node),
		}
	default:
		return nil
	}
}

func (service *FileSystemService) Root(ctx context.Context, req *api.RootRequest) (*api.RootResponse, error) {
	node, err := filesystem_service.GetRoot(service.fileSystem)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("root node not found"))
		}

		return nil, api.ToResponseError(err, err)
	}

	if node == nil {
		return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("root node is nil"))
	}

	return &api.RootResponse{
		Root: service.getApiNode(node),
	}, nil
}

func (service *FileSystemService) ReadDirAll(ctx context.Context, req *api.ReadDirAllRequest) (*api.ReadDirAllResponse, error) {
	nodes, err := service.fileSystem.ReadDir(req.NodeId)
	if err != nil {
		if err == sql.ErrNoRows {
			return &api.ReadDirAllResponse{Nodes: []*api.Node{}}, nil
		}

		return nil, api.ToResponseError(err, err)
	}

	var responseNodes []*api.Node

	for _, node := range nodes {
		responseNodes = append(responseNodes, service.getApiNode(node))
	}

	return &api.ReadDirAllResponse{
		Nodes: responseNodes,
	}, nil
}

func (service *FileSystemService) Lookup(ctx context.Context, req *api.LookupRequest) (*api.LookupResponse, error) {
	node, err := service.fileSystem.Lookup(req.NodeId, req.Name)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("node not found"))
		}

		return nil, api.ToResponseError(err, err)
	}

	if node == nil {
		return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("node is nil"))
	}

	response := &api.LookupResponse{
		Node: service.getApiNode(node),
	}

	return response, nil
}

func (service *FileSystemService) Create(ctx context.Context, req *api.CreateRequest) (*api.CreateResponse, error) {
	parentDirectory, err := service.fileSystem.Open(req.ParentNodeId)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("parent directory not found"))
		}

		return nil, api.ToResponseError(err, err)
	}

	if parentDirectory == nil {
		return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("parent directory is nil"))
	}

	if !parentDirectory.GetMode().IsDir() {
		return nil, api.ToResponseError(syscall.ENOTDIR, fmt.Errorf("parent node is not a directory"))
	}

	err = service.fileSystem.Touch(parentDirectory.GetId(), req.Name)
	if err != nil {
		return nil, api.ToResponseError(err, err)
	}

	return &api.CreateResponse{}, nil
}

// remove file
func (service *FileSystemService) Remove(ctx context.Context, req *api.RemoveRequest) (*api.RemoveResponse, error) {
	node, err := service.fileSystem.Lookup(req.ParentNodeId, req.Name)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("node not found"))
		}

		return nil, api.ToResponseError(err, err)
	}

	if node == nil {
		return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("node is nil"))
	}

	switch node.GetMode() {
	case fs.FileMode(0), fs.ModeSymlink:
		file, err := service.fileSystem.Open(node.GetId())
		if err != nil {
			if err == sql.ErrNoRows {
				return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("file not found"))
			}

			return nil, api.ToResponseError(err, err)
		}

		if file == nil {
			return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("file is nil"))
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

				err = service.mediaManager.DeleteTorrent(transaction, torrent, true)
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
			if err == sql.ErrNoRows {
				return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("directory not found"))
			}

			return nil, api.ToResponseError(err, err)
		}

		if directory == nil {
			return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("directory is nil"))
		}

		if !directory.GetMode().IsDir() {
			return nil, api.ToResponseError(syscall.ENOTDIR, fmt.Errorf("node is not a directory"))
		}

		err = service.fileSystem.RmDir(directory.GetId())
		if err != nil {
			return nil, api.ToResponseError(err, err)
		}
	default:
		return nil, api.ToResponseError(fmt.Errorf("unknown"), fmt.Errorf("unknown file mode %v", node.GetMode()))
	}

	return &api.RemoveResponse{}, nil
}

func (service *FileSystemService) Rename(ctx context.Context, req *api.RenameRequest) (*api.RenameResponse, error) {
	node, err := service.fileSystem.Lookup(req.OldParentNodeId, req.OldName)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("node not found"))
		}

		return nil, api.ToResponseError(err, err)
	}

	if node == nil {
		return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("node is nil"))
	}

	if service.isStreamable(node) {
		err := service.fileSystem.Rename(node.GetId(), req.NewName, req.NewParentNodeId)
		if err != nil {
			return nil, api.ToResponseError(err, err)
		}

		updatedDirectory, err := service.fileSystem.Open(node.GetId())
		if err != nil {
			if err == sql.ErrNoRows {
				return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("updated directory not found"))
			}

			return nil, api.ToResponseError(err, err)
		}

		if updatedDirectory == nil {
			return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("updated directory is nil"))
		}

		return &api.RenameResponse{
			Node: service.getApiNode(updatedDirectory),
		}, nil
	} else {
		err := service.fileSystem.Rename(node.GetId(), req.NewName, req.NewParentNodeId)
		if err != nil {
			return nil, api.ToResponseError(err, err)
		}

		newNode, err := service.fileSystem.Open(node.GetId())
		if err != nil {
			if err == sql.ErrNoRows {
				return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("new node not found"))
			}

			return nil, api.ToResponseError(err, err)
		}

		if newNode == nil {
			return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("new node is nil"))
		}

		return &api.RenameResponse{
			Node: service.getApiNode(newNode),
		}, nil
	}
}

func (service *FileSystemService) Mkdir(ctx context.Context, req *api.MkdirRequest) (*api.MkdirResponse, error) {
	parentNode, err := service.fileSystem.Open(req.ParentNodeId)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("parent node not found"))
		}

		return nil, api.ToResponseError(err, err)
	}

	if parentNode == nil {
		return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("parent node is nil"))
	}

	if !parentNode.GetMode().IsDir() {
		return nil, api.ToResponseError(syscall.ENOTDIR, fmt.Errorf("parent node is not a directory"))
	}

	err = service.fileSystem.MkDir(parentNode.GetId(), req.Name)
	if err != nil {
		return nil, api.ToResponseError(err, err)
	}

	directory, err := service.fileSystem.Lookup(parentNode.GetId(), req.Name)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("directory not found"))
		}

		return nil, api.ToResponseError(err, err)
	}

	if directory == nil {
		return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("directory is nil"))
	}

	if !directory.GetMode().IsDir() {
		return nil, api.ToResponseError(syscall.ENOTDIR, fmt.Errorf("node is not a directory"))
	}

	return &api.MkdirResponse{
		Node: service.getApiNode(directory),
	}, nil
}

func (service *FileSystemService) Link(ctx context.Context, req *api.LinkRequest) (*api.LinkResponse, error) {
	err := service.fileSystem.Link(req.NodeId, req.Name, req.ParentNodeId)
	if err != nil {
		return nil, api.ToResponseError(err, err)
	}

	linkedNode, err := service.fileSystem.Lookup(req.ParentNodeId, req.Name)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("linked node not found"))
		}

		return nil, api.ToResponseError(err, err)
	}

	if linkedNode == nil {
		return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("linked node is nil"))
	}

	return &api.LinkResponse{
		Node: service.getApiNode(linkedNode),
	}, nil
}

func (service *FileSystemService) ReadFile(ctx context.Context, req *api.ReadFileRequest) (*api.ReadFileResponse, error) {
	node, err := service.fileSystem.Open(req.NodeId)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("node not found"))
		}

		return nil, api.ToResponseError(err, err)
	}

	if node == nil {
		return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("node is nil"))
	}

	if node.GetMode().IsDir() {
		return nil, api.ToResponseError(syscall.EISDIR, fmt.Errorf("node is a directory"))
	}

	if service.isStreamable(node) {
		return nil, nil
	}

	content, err := service.fileSystem.ReadFile(node.GetId())
	if err != nil && err != syscall.ENOENT {
		return nil, api.ToResponseError(err, err)
	}

	if content == nil {
		return &api.ReadFileResponse{
			Data: make([]byte, 0),
		}, nil
	}

	return &api.ReadFileResponse{
		Data: content[req.Offset:],
	}, nil
}

func (service *FileSystemService) WriteFile(ctx context.Context, req *api.WriteFileRequest) (*api.WriteFileResponse, error) {
	node, err := service.fileSystem.Open(req.NodeId)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("node not found"))
		}

		return nil, api.ToResponseError(err, err)
	}

	if node == nil {
		return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("node is nil"))
	}

	if node.GetMode().IsDir() {
		return nil, api.ToResponseError(syscall.EISDIR, fmt.Errorf("node is a directory"))
	}

	if service.isStreamable(node) {
		return nil, nil
	}

	content, err := service.fileSystem.ReadFile(node.GetId())
	if err != nil {
		if err == sql.ErrNoRows {
			content = nil
		} else {
			return nil, api.ToResponseError(err, err)
		}
	}

	var data []byte

	if content == nil {
		data = req.Data
	} else {
		fmt.Printf("Overwriting file: %v\n", node.GetId())
		data = append(content[:req.Offset], req.Data...)
	}

	n, err := service.fileSystem.WriteFile(node.GetId(), data)
	if err != nil {
		return nil, api.ToResponseError(err, err)
	}

	if n < 0 {
		return &api.WriteFileResponse{
			BytesWritten: 0,
		}, nil
	}

	return &api.WriteFileResponse{
		BytesWritten: uint64(n),
	}, nil
}

func (service *FileSystemService) ReadLink(ctx context.Context, req *api.ReadLinkRequest) (*api.ReadLinkResponse, error) {
	path, err := service.fileSystem.ReadLink(req.NodeId)
	if err != nil {
		return nil, api.ToResponseError(err, err)
	}

	return &api.ReadLinkResponse{
		Path: path,
	}, nil
}

func (service *FileSystemService) GetFileInfo(ctx context.Context, req *api.GetFileInfoRequest) (*api.GetFileInfoResponse, error) {
	file, err := service.fileSystem.Open(req.NodeId)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("file not found"))
		}

		return nil, api.ToResponseError(err, err)
	}

	if file == nil {
		return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("file is nil"))
	}

	if !service.isStreamable(file) {
		return nil, nil
	}

	torrentFile, err := service.mediaManager.GetTorrentFileByFile(file)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("torrent file not found"))
		}

		return nil, api.ToResponseError(err, err)
	}

	if torrentFile == nil {
		return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("torrent file is nil"))
	}

	size := max(torrentFile.GetSize(), 0)

	return &api.GetFileInfoResponse{
		Size: uint64(size),
		Mode: uint32(file.GetMode()),
	}, nil
}

func (service *FileSystemService) GetStreamUrl(ctx context.Context, req *api.GetStreamUrlRequest) (*api.GetStreamUrlResponse, error) {
	file, err := service.fileSystem.Open(req.NodeId)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("file not found"))
		}

		return nil, api.ToResponseError(err, err)
	}

	if file == nil {
		return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("file is nil"))
	}

	if !service.isStreamable(file) {
		return nil, nil
	}

	torrentFile, err := service.mediaManager.GetTorrentFileByFile(file)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("torrent file not found"))
		}

		return nil, api.ToResponseError(err, err)
	}

	if torrentFile == nil {
		return nil, api.ToResponseError(syscall.ENOENT, fmt.Errorf("torrent file is nil"))
	}

	unrestrictResponse, err := real_debrid_api.UnrestrictLink(service.client, torrentFile.GetLink())
	if err != nil {
		return nil, api.ToResponseError(err, err)
	}

	response := &api.GetStreamUrlResponse{
		Url: unrestrictResponse.Download,
	}

	return response, nil
}
