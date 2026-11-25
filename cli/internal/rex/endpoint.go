package rex

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// Target is where and how to open the control WebSocket.
type Target struct {
	URL    string // WebSocket URL of /api/control
	Socket string // Unix socket path to dial, if any
}

// DefaultEndpoint is $REX_SERVER, or the personal server's socket.
func DefaultEndpoint() (string, error) {
	if server := os.Getenv("REX_SERVER"); server != "" {
		return server, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", errors.New("cannot find the Rex server socket: HOME is not set; set REX_SERVER")
	}
	if runtime.GOOS == "darwin" {
		return filepath.Join(home, "Library", "Application Support", "rex", "server.sock"), nil
	}
	if runtime.GOOS == "linux" {
		if dir := os.Getenv("XDG_RUNTIME_DIR"); dir != "" {
			return filepath.Join(dir, "rex", "server.sock"), nil
		}
	}
	state := os.Getenv("XDG_STATE_HOME")
	if state == "" {
		state = filepath.Join(home, ".local", "state")
	}
	return filepath.Join(state, "rex", "run", "server.sock"), nil
}

// ParseEndpoint accepts a socket path, a unix:// URL (percent-encoded),
// host:port, or an http(s):// or ws(s):// URL.
func ParseEndpoint(endpoint string) (Target, error) {
	switch {
	case strings.HasPrefix(endpoint, "/"):
		return Target{URL: "ws://rex/api/control", Socket: endpoint}, nil
	case strings.HasPrefix(endpoint, "unix://"):
		u, err := url.Parse(endpoint)
		if err != nil || u.Path == "" {
			return Target{}, fmt.Errorf("invalid Rex server address %q", endpoint)
		}
		return Target{URL: "ws://rex/api/control", Socket: u.Path}, nil
	case strings.Contains(endpoint, "://"):
		u, err := url.Parse(endpoint)
		if err != nil || u.Host == "" {
			return Target{}, fmt.Errorf("invalid Rex server address %q", endpoint)
		}
		switch u.Scheme {
		case "http", "ws":
			u.Scheme = "ws"
		case "https", "wss":
			u.Scheme = "wss"
		default:
			return Target{}, fmt.Errorf("unsupported Rex server address %q", endpoint)
		}
		u.Path = "/api/control"
		return Target{URL: u.String()}, nil
	case strings.Contains(endpoint, ":"):
		return Target{URL: "ws://" + endpoint + "/api/control"}, nil
	}
	return Target{}, fmt.Errorf("invalid Rex server address %q; use a socket path, unix:// URL, or host:port", endpoint)
}
