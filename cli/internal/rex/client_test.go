package rex

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// fakeServer speaks enough of rex.control.v1 over a Unix socket: the
// handshake, an event before each response, and three methods.
func fakeServer(t *testing.T, revision int) string {
	t.Helper()
	socket := filepath.Join(t.TempDir(), "s.sock")
	ln, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/control" {
			http.NotFound(w, r)
			return
		}
		c, err := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{Protocol}})
		if err != nil {
			return
		}
		defer c.CloseNow()
		ctx := r.Context()
		var hello map[string]any
		if _, data, err := c.Read(ctx); err != nil || json.Unmarshal(data, &hello) != nil || hello["type"] != "hello" {
			return
		}
		welcome, _ := json.Marshal(map[string]any{"type": "welcome", "protocol": Protocol, "api_revision": revision})
		c.Write(ctx, websocket.MessageText, welcome)
		for {
			_, data, err := c.Read(ctx)
			if err != nil {
				return
			}
			var req struct {
				ID      string         `json:"id"`
				Method  string         `json:"method"`
				Payload map[string]any `json:"payload"`
			}
			json.Unmarshal(data, &req)
			event, _ := json.Marshal(map[string]any{"type": "event", "event": "noise"})
			c.Write(ctx, websocket.MessageText, event)
			res := map[string]any{"type": "response", "id": req.ID}
			switch {
			case req.Method == "client.action" && req.Payload["action"] == "echo":
				res["payload"] = map[string]any{"result": req.Payload["args"], "client_actions": nil}
			case req.Method == "client.action":
				res["error"] = map[string]any{"code": "internal", "status": 500, "message": "unknown plugin: x/y"}
			case req.Method == "server.config_reload":
				res["error"] = map[string]any{"code": "forbidden", "status": 403, "message": "local only"}
			default:
				res["payload"] = map[string]any{"rex_version": "test", "api_revision": revision}
			}
			out, _ := json.Marshal(res)
			c.Write(ctx, websocket.MessageText, out)
		}
	})}
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })
	return socket
}

func TestClient(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, err := Dial(ctx, "unix://"+fakeServer(t, 19), "test")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	var got map[string]string
	if err := c.Action(ctx, "echo", map[string]any{"plugin": "a/b"}, &got); err != nil || got["plugin"] != "a/b" {
		t.Fatalf("echo: %v %v", got, err)
	}
	var rexErr *Error
	if err := c.Action(ctx, "amber_update", nil, nil); !errors.As(err, &rexErr) || rexErr.Message != "unknown plugin: x/y" {
		t.Fatalf("want the Lua error, got %v", err)
	}
	if _, err := c.ReloadConfig(ctx); err == nil || !strings.Contains(err.Error(), "local socket") {
		t.Fatalf("reload over a remote connection: %v", err)
	}
	if v, err := c.Version(ctx); err != nil || v.RexVersion != "test" {
		t.Fatalf("version: %+v %v", v, err)
	}
}

func TestDialRejectsOldRevision(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := Dial(ctx, fakeServer(t, 12), "test"); err == nil || !strings.Contains(err.Error(), "update Rex") {
		t.Fatalf("got %v", err)
	}
}

func TestParseEndpoint(t *testing.T) {
	cases := map[string]Target{
		"/tmp/a b/s.sock": {URL: "ws://rex/api/control", Socket: "/tmp/a b/s.sock"},
		"unix:///Users/x/Library/Application%20Support/rex/server.sock": {URL: "ws://rex/api/control", Socket: "/Users/x/Library/Application Support/rex/server.sock"},
		"studio:7297":             {URL: "ws://studio:7297/api/control"},
		"https://rex.example.com": {URL: "wss://rex.example.com/api/control"},
	}
	for in, want := range cases {
		got, err := ParseEndpoint(in)
		if err != nil || got != want {
			t.Errorf("%s: got %+v %v, want %+v", in, got, err, want)
		}
	}
	if _, err := ParseEndpoint("studio"); err == nil {
		t.Error("a bare host label should be rejected")
	}
}
