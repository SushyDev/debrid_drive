package garbage_cleaner

import (
	"fmt"
	"time"

	"debrid_drive/logger"

	vfs "github.com/sushydev/vfs_go"
	vfs_node "github.com/sushydev/vfs_go/node"
)

type GarbageCleaner struct {
	fileSystem *vfs.FileSystem
	logger     *logger.Logger
}

func NewGarbageCleaner(fileSystem *vfs.FileSystem) *GarbageCleaner {
	logger, err := logger.NewLogger("Garbage Cleaner")
	if err != nil {
		panic(err)
	}

	return &GarbageCleaner{
		fileSystem: fileSystem,
		logger:     logger,
	}
}

func (instance *GarbageCleaner) Cron() {
	interval := 10 * time.Minute

	for {
		<-time.After(interval)

		err := instance.Poll()
		if err != nil {
			instance.logger.Error("Failed to run garbage cleaner", err)
		}
	}
}

func (instance *GarbageCleaner) Poll() error {
	instance.logger.Info("Garbage cleaner started")

	root := instance.fileSystem.GetRoot()
	mediaManager, err := instance.fileSystem.FindOrCreateDirectory("media_manager", root)
	if err != nil {
		instance.logger.Error("Failed to get media manager directory", err)
		return err
	}

	instance.cleanEmptyDirectories(mediaManager)

	instance.logger.Info("Garbage cleaner complete")

	return nil
}

func (instance *GarbageCleaner) cleanEmptyDirectories(directory *vfs_node.Directory) {
	childNodes, err := instance.fileSystem.GetChildNodes(directory)
	if err != nil {
		instance.logger.Error("Failed to get child nodes", err)
		return
	}

	for _, childNode := range childNodes {
		if childNode.GetType() != vfs_node.DirectoryNode {
			continue
		}

		directory, err := instance.fileSystem.GetDirectory(childNode.GetIdentifier())
		if err != nil {
			instance.logger.Error("Failed to get directory", err)
			continue
		}

		childNodes, err := instance.fileSystem.GetChildNodes(directory)
		if err != nil {
			instance.logger.Error("Failed to get child nodes", err)
			continue
		}

		if len(childNodes) > 0 {
			instance.cleanEmptyDirectories(directory)

			newChildNodes, err := instance.fileSystem.GetChildNodes(directory)
			if err != nil {
				instance.logger.Error("Failed to get child nodes", err)
				continue
			}

			if len(newChildNodes) > 0 {
				continue
			}
		}

		instance.logger.Info(fmt.Sprintf("Deleting empty directory %s", directory.GetName()))

		err = instance.fileSystem.DeleteDirectory(directory)
		if err != nil {
			instance.logger.Error("Failed to delete directory", err)
			continue
		}
	}
}
