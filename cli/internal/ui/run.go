package ui

import (
	"context"
	"errors"
	"fmt"
	"io"
	"sync"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/rawnly/amber/cli/internal/amber"
	"github.com/rawnly/amber/cli/internal/engine"
)

// ErrFailed reports that at least one plugin operation failed; details were
// already shown.
var ErrFailed = errors.New("some plugins failed")

// Run shows the full-screen interface until the user quits.
func Run(opts Options) error {
	m := newModel(opts)
	defer m.cancel()
	final, err := tea.NewProgram(m).Run()
	if err != nil {
		return err
	}
	fm := final.(*model)
	if fm.connErr != nil {
		return fm.connErr
	}
	if fm.failures() > 0 {
		return ErrFailed
	}
	return nil
}

// RunPlain runs an operation without the full-screen interface, printing one
// line per plugin; for pipes, logs, and CI.
func RunPlain(ctx context.Context, w io.Writer, s *Session, op Op, target string, parallel int, reload bool) error {
	plugins, err := selectPlugins(ctx, s, op, target)
	if err != nil {
		return err
	}
	if len(plugins) == 0 {
		lipgloss.Fprintf(w, "%s nothing to %s\n", styleDim.Render("·"), op)
		return nil
	}
	if parallel <= 0 {
		parallel = 4
	}
	var (
		mu      sync.Mutex
		wg      sync.WaitGroup
		failed  int
		changed bool
		sem     = make(chan struct{}, parallel)
	)
	nameWidth := 0
	for _, p := range plugins {
		nameWidth = max(nameWidth, len(p.Name))
	}
	for _, p := range plugins {
		wg.Add(1)
		go func(p *amber.Plugin) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			var line string
			if op == OpCheck {
				c, err := s.Backend.Check(ctx, p, func(engine.Event) {})
				line = plainCheck(c, err)
				if err != nil {
					mu.Lock()
					failed++
					mu.Unlock()
				}
			} else {
				res, err := s.Backend.Run(ctx, engine.Op(op), p, func(engine.Event) {})
				line = plainResult(op, res, err)
				mu.Lock()
				if err != nil {
					failed++
				} else if changedStatus(res.Status) {
					changed = true
				}
				mu.Unlock()
			}
			mu.Lock()
			lipgloss.Fprintf(w, "%s  %s\n", styleName.Render(fmt.Sprintf("%-*s", nameWidth, p.Name)), line)
			mu.Unlock()
		}(p)
	}
	wg.Wait()

	if changed && reload && s.Reload != nil {
		diags, err := s.Reload(ctx)
		if err != nil {
			lipgloss.Fprintln(w, styleErr.Render(iconFailed+" Rex reload failed: "+err.Error()))
			failed++
		} else {
			lipgloss.Fprintln(w, styleOK.Render(iconUpdated+" Reloaded Rex config"))
			for _, d := range diags {
				lipgloss.Fprintf(w, "  %s %s %s\n", styleWarn.Render(d.Severity), styleDim.Render(d.Source), d.Message)
			}
		}
	}
	if failed > 0 {
		return ErrFailed
	}
	return nil
}

func selectPlugins(ctx context.Context, s *Session, op Op, target string) ([]*amber.Plugin, error) {
	if target != "" {
		p, ok := s.Info.Find(target)
		if !ok {
			return nil, fmt.Errorf("unknown plugin: %s", target)
		}
		if !p.Managed() {
			return nil, fmt.Errorf("%s is %s; Amber does not manage it", target, unmanagedReason(p))
		}
		return []*amber.Plugin{p}, nil
	}
	var out []*amber.Plugin
	for i := range s.Info.Plugins {
		p := &s.Info.Plugins[i]
		if !p.Managed() {
			continue
		}
		r := &row{p: p, state: s.Backend.State(ctx, p), hasState: true}
		if eligible(op, r) {
			out = append(out, p)
		}
	}
	return out, nil
}

func plainResult(op Op, res engine.Result, err error) string {
	if err != nil {
		return styleErr.Render(iconFailed + " " + string(op) + " failed: " + err.Error())
	}
	if !changedStatus(res.Status) {
		text := styleDim.Render("· " + string(res.Status))
		if res.Message != "" {
			text += styleDim.Render(" (" + res.Message + ")")
		}
		return text
	}
	return styleOK.Render(iconUpdated) + " " + resultDetail(&res)
}

func plainCheck(c engine.Check, err error) string {
	if err != nil {
		return styleErr.Render(iconFailed + " check failed: " + err.Error())
	}
	if !c.Outdated {
		return styleDim.Render("· up to date")
	}
	text := styleWarn.Render(iconOutdated) + " " + styleHash.Render(short(c.Current)) + styleDim.Render(" → ") + styleHash.Render(short(c.Target))
	if c.TargetRef != "" {
		text += " " + styleRef.Render(c.TargetRef)
	}
	if n := len(c.Commits); n > 0 {
		text += styleDim.Render(fmt.Sprintf("  %d new commit%s", n, plural(n)))
	}
	return text
}
