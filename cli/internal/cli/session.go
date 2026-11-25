package cli

import (
	"context"
	"os"
	"time"

	"github.com/rawnly/amber/cli/internal/amber"
	"github.com/rawnly/amber/cli/internal/engine"
	"github.com/rawnly/amber/cli/internal/rex"
	"github.com/rawnly/amber/cli/internal/ui"
)

// globals are the flags shared by every command.
type globals struct {
	server   string
	noReload bool
	plain    bool
	parallel int
}

// conn is an open Rex connection with Amber's configuration.
type conn struct {
	client  *rex.Client
	info    *amber.Info
	session *ui.Session
}

func (g *globals) connect(ctx context.Context) (*conn, error) {
	dialCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	client, err := rex.Dial(dialCtx, g.server, Version)
	if err != nil {
		return nil, err
	}
	infoCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	info, err := amber.Fetch(infoCtx, client)
	if err != nil {
		client.Close()
		return nil, err
	}
	s := &ui.Session{
		Info:    info,
		Backend: engine.New(info, client),
		Refresh: func(ctx context.Context) (*amber.Info, error) { return amber.Fetch(ctx, client) },
	}
	if !g.noReload {
		s.Reload = func(ctx context.Context) ([]rex.Diagnostic, error) {
			ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
			defer cancel()
			return client.ReloadConfig(ctx)
		}
	}
	return &conn{client: client, info: info, session: s}, nil
}

func (c *conn) Close() { c.client.Close() }

// interactive reports whether stdin and stdout are terminals.
func interactive() bool {
	return isTerminal(os.Stdout) && isTerminal(os.Stdin)
}

func isTerminal(f *os.File) bool {
	fi, err := f.Stat()
	return err == nil && fi.Mode()&os.ModeCharDevice != 0
}
