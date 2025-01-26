package poller

import (
	real_debrid_api "github.com/sushydev/real_debrid_go/api"
)

func GetEntries(torrents real_debrid_api.Torrents) []*real_debrid_api.Torrent {
	var entries []*real_debrid_api.Torrent

	for _, torrent := range torrents {
		// Not downloaded yet
		if torrent.Status != "downloaded" {
			continue
		}

		// No files selected
		if torrent.Bytes == 0 {
			continue
		}

		entries = append(entries, torrent)
	}

	return entries
}
