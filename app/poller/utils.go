package poller

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"

	"golang.org/x/net/html"
)

func setupHttpClient() *http.Client {
	transport := &http.Transport{
		MaxIdleConns:        100,
		MaxIdleConnsPerHost: 100,
		MaxConnsPerHost:     100,
		IdleConnTimeout:     30 * time.Second,
		DisableCompression:  true,
		ForceAttemptHTTP2:   true,
	}

	return &http.Client{
		Transport: transport,
	}
}

func createRequest(url string) *http.Request {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		log.Fatal("Error creating request: ", err)
	}

	req.Header.Set("User-Agent", "")
	req.Header.Set("Connection", "keep-alive")
	req.Header.Set("Cache-Control", "no-cache")

	return req
}

func getHash(client *http.Client, req *http.Request, element string) ([32]byte, error) {
	reqCopy := new(http.Request)
	*reqCopy = *req

	body, statusCode, err := fetchPage(client, reqCopy)
	if err != nil {
		return [32]byte{}, err
	}
	defer body.Close()

	if statusCode != http.StatusOK {
		return [32]byte{}, fmt.Errorf("status code is not 200. Got %d", statusCode)
	}

	hash, err := extractAndHash(body, element)
	if err != nil {
		return [32]byte{}, err
	}

	return hash, nil
}

func fetchPage(client *http.Client, req *http.Request) (io.ReadCloser, int, error) {
	resp, err := client.Do(req)
	if err != nil {
		return nil, 0, err
	}

	return resp.Body, resp.StatusCode, nil
}

func extractAndHash(body io.ReadCloser, element string) ([32]byte, error) {
	doc, err := html.Parse(body)
	if err != nil {
		return [32]byte{}, err
	}

	tableNode := findTableNode(doc, element)
	if tableNode == nil {
		return [32]byte{}, fmt.Errorf("table not found")
	}

	tableHTML := renderTableHTML(tableNode)
	if tableHTML == "" {
		return [32]byte{}, fmt.Errorf("table is empty")
	}

	return sha256.Sum256([]byte(tableHTML)), nil
}

func findTableNode(n *html.Node, element string) *html.Node {
	if n.Type == html.ElementNode && n.Data == element {
		return n
	}

	for c := n.FirstChild; c != nil; c = c.NextSibling {
		result := findTableNode(c, element)
		if result != nil {
			return result
		}
	}

	return nil
}

func renderTableHTML(node *html.Node) string {
	buffer := bytes.NewBuffer(make([]byte, 0, 1024*1024*10))

	for c := node.FirstChild; c != nil; c = c.NextSibling {
		if err := html.Render(buffer, c); err != nil {
			// Continue rendering other children even if one fails
			continue
		}
	}

	return buffer.String()
}
