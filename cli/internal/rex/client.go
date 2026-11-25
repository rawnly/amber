// Package rex is a minimal client for the Rex server's control API
// (WebSocket subprotocol rex.control.v1). It covers only what Amber needs:
// running configuration actions, reloading the configuration, and reading the
// server version.
package rex

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"sync"

	"github.com/coder/websocket"
)

// Protocol is the control subprotocol Amber speaks.
const Protocol = "rex.control.v1"

const (
	apiRevision    = 19
	apiMinRevision = 18
)

// Error is a failure reported by the Rex server for one request.
type Error struct {
	Method  string
	Code    string
	Status  int
	Message string
}

func (e *Error) Error() string {
	if e.Message == "" {
		return fmt.Sprintf("rex %s failed: %s (%d)", e.Method, e.Code, e.Status)
	}
	return e.Message
}

// Client is one control connection. It is safe for concurrent use.
type Client struct {
	conn     *websocket.Conn
	revision int

	writeMu sync.Mutex
	mu      sync.Mutex
	nextID  int
	pending map[string]chan response
	closed  error
	done    chan struct{}
}

type response struct {
	Payload json.RawMessage `json:"payload"`
	Error   *struct {
		Code    string `json:"code"`
		Status  int    `json:"status"`
		Message string `json:"message"`
	} `json:"error"`
}

type envelope struct {
	Type string `json:"type"`
	ID   string `json:"id"`
	response
}

// Dial connects to the Rex server at endpoint and completes the handshake.
// An empty endpoint uses DefaultEndpoint.
func Dial(ctx context.Context, endpoint string, version string) (*Client, error) {
	if endpoint == "" {
		var err error
		endpoint, err = DefaultEndpoint()
		if err != nil {
			return nil, err
		}
	}
	target, err := ParseEndpoint(endpoint)
	if err != nil {
		return nil, err
	}
	opts := &websocket.DialOptions{Subprotocols: []string{Protocol}}
	if target.Socket != "" {
		socket := target.Socket
		opts.HTTPClient = &http.Client{Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "unix", socket)
			},
		}}
	}
	conn, _, err := websocket.Dial(ctx, target.URL, opts)
	if err != nil {
		return nil, fmt.Errorf("cannot connect to the Rex server at %s: %w; is it running?", endpoint, err)
	}
	conn.SetReadLimit(64 << 20)
	if conn.Subprotocol() != Protocol {
		conn.CloseNow()
		return nil, fmt.Errorf("the Rex server at %s did not accept %s", endpoint, Protocol)
	}

	hello, _ := json.Marshal(map[string]any{
		"type":             "hello",
		"api_revision":     apiRevision,
		"api_min_revision": apiMinRevision,
		"client":           map[string]any{"kind": "tool", "name": "amber", "version": version},
	})
	if err := conn.Write(ctx, websocket.MessageText, hello); err != nil {
		conn.CloseNow()
		return nil, fmt.Errorf("rex handshake failed: %w", err)
	}
	var welcome struct {
		Type        string `json:"type"`
		APIRevision int    `json:"api_revision"`
		Message     string `json:"message"`
	}
	for welcome.Type != "welcome" {
		_, data, err := conn.Read(ctx)
		if err != nil {
			conn.CloseNow()
			return nil, fmt.Errorf("rex handshake failed: %w", err)
		}
		if err := json.Unmarshal(data, &welcome); err != nil {
			conn.CloseNow()
			return nil, fmt.Errorf("rex handshake failed: invalid message: %w", err)
		}
		if welcome.Type == "error" {
			conn.CloseNow()
			return nil, fmt.Errorf("rex refused the connection: %s", welcome.Message)
		}
	}
	if welcome.APIRevision < apiMinRevision {
		conn.CloseNow()
		return nil, fmt.Errorf("the Rex server speaks API revision %d; Amber needs %d or newer, so update Rex", welcome.APIRevision, apiMinRevision)
	}

	c := &Client{
		conn:     conn,
		revision: welcome.APIRevision,
		pending:  map[string]chan response{},
		done:     make(chan struct{}),
	}
	go c.readLoop()
	return c, nil
}

// Revision is the API revision the server agreed to.
func (c *Client) Revision() int { return c.revision }

// Close ends the connection; in-flight requests fail.
func (c *Client) Close() error {
	err := c.conn.Close(websocket.StatusNormalClosure, "")
	<-c.done
	return err
}

func (c *Client) readLoop() {
	defer close(c.done)
	for {
		_, data, err := c.conn.Read(context.Background())
		if err != nil {
			c.fail(fmt.Errorf("connection to the Rex server ended: %w", err))
			return
		}
		var msg envelope
		if json.Unmarshal(data, &msg) != nil || msg.Type != "response" {
			continue // events and unknown messages are not used by Amber
		}
		c.mu.Lock()
		ch := c.pending[msg.ID]
		delete(c.pending, msg.ID)
		c.mu.Unlock()
		if ch != nil {
			ch <- msg.response
		}
	}
}

func (c *Client) fail(err error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.closed = err
	for id, ch := range c.pending {
		delete(c.pending, id)
		close(ch)
	}
}

// Call sends one request and decodes its payload into result, which may be nil.
func (c *Client) Call(ctx context.Context, method string, payload any, result any) error {
	c.mu.Lock()
	if c.closed != nil {
		err := c.closed
		c.mu.Unlock()
		return err
	}
	c.nextID++
	id := strconv.Itoa(c.nextID)
	ch := make(chan response, 1)
	c.pending[id] = ch
	c.mu.Unlock()

	request := map[string]any{"type": "request", "id": id, "method": method}
	if payload != nil {
		request["payload"] = payload
	}
	data, err := json.Marshal(request)
	if err != nil {
		c.forget(id)
		return err
	}
	c.writeMu.Lock()
	err = c.conn.Write(ctx, websocket.MessageText, data)
	c.writeMu.Unlock()
	if err != nil {
		c.forget(id)
		return fmt.Errorf("rex %s: %w", method, err)
	}

	select {
	case <-ctx.Done():
		c.forget(id)
		return fmt.Errorf("rex %s: %w; the server may still finish it", method, ctx.Err())
	case res, ok := <-ch:
		if !ok {
			c.mu.Lock()
			err := c.closed
			c.mu.Unlock()
			return fmt.Errorf("rex %s may have run: %w", method, err)
		}
		if res.Error != nil {
			return &Error{Method: method, Code: res.Error.Code, Status: res.Error.Status, Message: res.Error.Message}
		}
		if result == nil || len(res.Payload) == 0 {
			return nil
		}
		if err := json.Unmarshal(res.Payload, result); err != nil {
			return fmt.Errorf("rex %s returned an unexpected result: %w", method, err)
		}
		return nil
	}
}

func (c *Client) forget(id string) {
	c.mu.Lock()
	delete(c.pending, id)
	c.mu.Unlock()
}

// Action runs a configuration-file action and decodes what it returned into
// result. A Lua error in the action comes back as *Error with its message.
func (c *Client) Action(ctx context.Context, name string, args map[string]any, result any) error {
	payload := map[string]any{"action": name}
	if len(args) > 0 {
		payload["args"] = args
	}
	var out struct {
		Result json.RawMessage `json:"result"`
	}
	if err := c.Call(ctx, "client.action", payload, &out); err != nil {
		return err
	}
	if result == nil || len(out.Result) == 0 {
		return nil
	}
	if err := json.Unmarshal(out.Result, result); err != nil {
		return fmt.Errorf("action %s returned an unexpected result: %w", name, err)
	}
	return nil
}

// Diagnostic is one problem the server found while loading its configuration.
type Diagnostic struct {
	Severity string `json:"severity"`
	Source   string `json:"source"`
	Message  string `json:"message"`
}

// ReloadConfig reloads the server's configuration file. It works only over the
// local Unix socket.
func (c *Client) ReloadConfig(ctx context.Context) ([]Diagnostic, error) {
	var out struct {
		Diagnostics []Diagnostic `json:"diagnostics"`
	}
	if err := c.Call(ctx, "server.config_reload", map[string]any{}, &out); err != nil {
		var rexErr *Error
		if errors.As(err, &rexErr) && rexErr.Status == 403 {
			return nil, fmt.Errorf("rex only reloads its configuration over the local socket; run `rex config reload` on the server")
		}
		return nil, err
	}
	return out.Diagnostics, nil
}

// Version describes the connected server.
type Version struct {
	RexVersion  string `json:"rex_version"`
	Platform    string `json:"platform"`
	APIRevision int    `json:"api_revision"`
}

// Version reads the server version.
func (c *Client) Version(ctx context.Context) (Version, error) {
	var v Version
	err := c.Call(ctx, "server.version", map[string]any{}, &v)
	return v, err
}
