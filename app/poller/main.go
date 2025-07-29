package poller

import (
	"context"
	"net/http"
	"time"
)

type changePoller struct {
	url     string
	element string
	action  func(hash [32]byte)

	lastHash [32]byte
	client   *http.Client
	req      *http.Request
	ticks    time.Duration

	ctx    context.Context
	cancel context.CancelFunc
}

func NewChangePoller(url string, element string, ticks time.Duration, action func(hash [32]byte)) *changePoller {
	client := setupHttpClient()
	req := createRequest(url)

	ctx, cancel := context.WithCancel(context.Background())

	return &changePoller{
		url:     url,
		element: element,
		action:  action,

		lastHash: [32]byte{},
		client:   client,
		req:      req,
		ticks:    ticks,

		ctx:    ctx,
		cancel: cancel,
	}
}

func (p *changePoller) Start() {
	ticker := time.NewTicker(p.ticks)
	defer ticker.Stop()

	<-ticker.C

	for {
		select {
		case <-p.ctx.Done():
			return
		case <-ticker.C:
			p.exec()
		}
	}
}

func (p *changePoller) Stop() {
	p.cancel()
}

func (p *changePoller) exec() {
	hash, err := getHash(p.client, p.req, p.element)
	if err != nil {
		return
	}

	if hash != p.lastHash {
		p.lastHash = hash
		p.action(hash)
	}
}

type timePoller struct {
	action func()

	ticks time.Duration

	ctx    context.Context
	cancel context.CancelFunc
}

func NewTimePoller(ticks time.Duration, action func()) *timePoller {
	ctx, cancel := context.WithCancel(context.Background())

	return &timePoller{
		action: action,
		ticks:  ticks,
		ctx:    ctx,
		cancel: cancel,
	}
}

func (p *timePoller) Start() {
	ticker := time.NewTicker(p.ticks)
	defer ticker.Stop()

	<-ticker.C

	for {
		select {
		case <-p.ctx.Done():
			return
		case <-ticker.C:
			p.exec()
		}
	}
}

func (p *timePoller) Stop() {
	p.cancel()
}

func (p *timePoller) exec() {
	if p.action != nil {
		p.action()
	}
}
