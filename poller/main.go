package poller

import (
	"context"
	"net/http"
	"runtime"
	"time"
)

type changeFunc func(hash [32]byte)

type poller struct {
	url     string
	element string
	changeFunc  func(hash [32]byte)

	lastHash [32]byte
	client   *http.Client
	req      *http.Request
	ticks    time.Duration

	ctx    context.Context
	cancel context.CancelFunc
}

func New(url string, element string, ticks time.Duration, changeFunc func(hash [32]byte)) *poller {
	client := setupHttpClient()
	req := createRequest(url)

	ctx, cancel := context.WithCancel(context.Background())

	return &poller{
		url:     url,
		element: element,
		changeFunc:  changeFunc,

		lastHash: [32]byte{},
		client:   client,
		req:      req,
		ticks:    ticks,

		ctx:    ctx,
		cancel: cancel,
	}
}

func (p *poller) Start() {
	p.exec()

	ticker := time.NewTicker(p.ticks)
	defer ticker.Stop()

	for {
		select {
		case <-p.ctx.Done():
			return
		case <-ticker.C:
			p.exec()
		}
	}
}

func (p *poller) Stop() {
	p.cancel()
}

func (p *poller) exec() {
	hash, err := getHash(p.client, p.req, p.element)
	if err != nil {
		return
	}

	if hash != p.lastHash {
		p.lastHash = hash
		p.changeFunc(hash)
	}

	runtime.GC()
}

