package ui

import (
	"io"
	"strings"

	"charm.land/lipgloss/v2"
	"charm.land/lipgloss/v2/table"

	"github.com/rawnly/amber/cli/internal/amber"
	"github.com/rawnly/amber/cli/internal/engine"
)

// PrintList prints a table of plugins and their local state.
func PrintList(w io.Writer, info *amber.Info, states map[string]engine.State) {
	if len(info.Plugins) == 0 {
		lipgloss.Fprintln(w, styleDim.Render("No plugins declared."))
		return
	}
	rows := make([][]string, 0, len(info.Plugins))
	for i := range info.Plugins {
		p := &info.Plugins[i]
		r := &row{p: p}
		if st, ok := states[p.Name]; ok {
			r.state, r.hasState = st, true
		}
		icon, status := listStatus(r)
		commit, ref := "", firstNonEmpty(p.Version, r.state.Branch)
		if r.state.Installed {
			commit = short(r.state.Head)
		}
		if p.LocalPath {
			ref = p.Dir
		}
		note := ""
		if p.Managed() && r.state.Installed {
			note = attention(r)
		}
		if note == "" && p.LoadError != "" && (p.LocalPath || r.state.Installed) {
			note = firstLine(p.LoadError)
		}
		rows = append(rows, []string{icon + " " + p.Name, status, commit, ref, note})
	}
	t := table.New().
		BorderTop(false).BorderBottom(false).BorderLeft(false).BorderRight(false).
		BorderColumn(false).BorderHeader(false).BorderRow(false).
		Headers("PLUGIN", "STATUS", "COMMIT", "VERSION", "NOTE").
		Rows(rows...).
		StyleFunc(func(row, col int) lipgloss.Style {
			s := lipgloss.NewStyle().PaddingRight(2)
			if row == table.HeaderRow {
				return s.Foreground(colorMuted).Bold(true)
			}
			switch col {
			case 2:
				return s.Foreground(colorPurple)
			case 3:
				return s.Foreground(colorBlue)
			case 4:
				return s.Foreground(colorYellow)
			}
			return s
		})
	lipgloss.Fprintln(w, t.Render())
	lipgloss.Fprintln(w, styleFaint.Render(" root "+info.Root+"   lockfile "+info.Lockfile))
}

func listStatus(r *row) (string, string) {
	switch {
	case !r.p.Enabled:
		return styleFaint.Render(iconDisabled), styleFaint.Render("disabled")
	case r.p.LocalPath:
		return styleLocal.Render(iconLocal), styleLocal.Render(firstNonEmpty(r.p.LoadStatus, "local"))
	case r.hasState && !r.state.Installed:
		return styleDim.Render(iconMissing), styleDim.Render("not installed")
	case r.p.LoadStatus == "loaded" && attention(r) == "":
		return styleOK.Render(iconInstalled), styleOK.Render("loaded")
	}
	return styleWarn.Render(iconInstalled), styleWarn.Render(firstNonEmpty(r.p.LoadStatus, "installed"))
}

// CheckLevel is how serious a doctor finding is.
type CheckLevel int

const (
	CheckOK CheckLevel = iota
	CheckWarn
	CheckFail
)

// CheckResult is one line of `amber doctor`.
type CheckResult struct {
	Level  CheckLevel
	Title  string
	Detail string // extra context, or the fix
}

// PrintChecks prints doctor findings grouped under a heading.
func PrintChecks(w io.Writer, heading string, checks []CheckResult) {
	lipgloss.Fprintln(w, styleSection.Render(heading))
	for _, c := range checks {
		icon := styleOK.Render("✓")
		switch c.Level {
		case CheckWarn:
			icon = styleWarn.Render("!")
		case CheckFail:
			icon = styleErr.Render(iconFailed)
		}
		lipgloss.Fprintf(w, "  %s %s\n", icon, c.Title)
		if c.Detail != "" {
			for _, l := range strings.Split(c.Detail, "\n") {
				lipgloss.Fprintf(w, "    %s\n", styleDim.Render(l))
			}
		}
	}
	lipgloss.Fprintln(w)
}

// PluginChecks turns local plugin state into doctor findings.
func PluginChecks(info *amber.Info, states map[string]engine.State) []CheckResult {
	var out []CheckResult
	for i := range info.Plugins {
		p := &info.Plugins[i]
		r := &row{p: p, state: states[p.Name], hasState: true}
		switch {
		case !p.Enabled:
			continue
		case p.LocalPath:
			if p.LoadStatus != "loaded" {
				out = append(out, CheckResult{CheckWarn, p.Name + " (local) is " + firstNonEmpty(p.LoadStatus, "not loaded"), firstLine(p.LoadError)})
			} else {
				out = append(out, CheckResult{CheckOK, p.Name + " (local)", ""})
			}
		case !r.state.Installed:
			out = append(out, CheckResult{CheckWarn, p.Name + " is not installed", "run: amber install " + p.Name})
		case attention(r) != "":
			out = append(out, CheckResult{CheckWarn, p.Name + ": " + attention(r), ""})
		case r.state.Dirty:
			out = append(out, CheckResult{CheckWarn, p.Name + " has local changes", "restore and update refuse to touch it until they are committed or removed"})
		default:
			out = append(out, CheckResult{CheckOK, p.Name + " " + short(r.state.Head), ""})
		}
	}
	return out
}
