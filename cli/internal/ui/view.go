package ui

import (
	"fmt"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/rawnly/amber/cli/internal/engine"
)

type section struct {
	title string
	rows  []*row
}

// sections groups plugins like lazy.nvim does; each plugin appears once, in
// the first section that matches it.
func (m *model) sections() []section {
	defs := []struct {
		title string
		match func(*row) bool
	}{
		{"Working", func(r *row) bool { return r.task != nil || r.queued != OpNone }},
		{"Failed", func(r *row) bool { return r.err != nil }},
		{"Updated", func(r *row) bool { return r.result != nil && changedStatus(r.result.Status) }},
		{"Updates available", func(r *row) bool { return r.check != nil && r.check.Outdated }},
		{"Needs attention", func(r *row) bool { return r.p.Managed() && r.hasState && r.state.Installed && attention(r) != "" }},
		{"Not installed", func(r *row) bool { return r.p.Managed() && r.hasState && !r.state.Installed }},
		{"Installed", func(r *row) bool { return r.p.Managed() }},
		{"Local", func(r *row) bool { return r.p.Enabled && r.p.LocalPath }},
		{"Disabled", func(r *row) bool { return !r.p.Enabled }},
	}
	seen := map[*row]bool{}
	var out []section
	for _, d := range defs {
		s := section{title: d.title}
		for _, r := range m.rows {
			if !seen[r] && d.match(r) {
				seen[r] = true
				s.rows = append(s.rows, r)
			}
		}
		if len(s.rows) > 0 {
			out = append(out, s)
		}
	}
	return out
}

// order is the cursor order: rows as they appear on screen.
func (m *model) order() []*row {
	var out []*row
	for _, s := range m.sections() {
		out = append(out, s.rows...)
	}
	return out
}

func changedStatus(s engine.Status) bool {
	return s != engine.StatusSkipped && s != engine.StatusUpToDate
}

// attention names the most important local problem with an installed plugin.
func attention(r *row) string {
	st := r.state
	switch {
	case st.Err != nil:
		return st.Err.Error()
	case st.Locked == "":
		return "not in the lockfile"
	case st.Head != "" && st.Locked != st.Head:
		return "checkout differs from lockfile " + short(st.Locked) + "; restore with r"
	case st.NeedsBuild:
		return "not built for the locked commit; build with b"
	case r.p.LoadStatus == "error":
		return "setup failed: " + firstLine(r.p.LoadError)
	case r.p.LoadStatus == "missing":
		return firstLine(r.p.LoadError)
	case st.VersionMatches != nil && !*st.VersionMatches:
		return "checkout does not match " + r.p.Version + "; update with u"
	}
	return ""
}

func (m *model) View() tea.View {
	v := tea.NewView(m.render())
	v.AltScreen = true
	v.WindowTitle = "amber"
	return v
}

func (m *model) render() string {
	w := max(40, m.width)
	header := m.renderHeader(w)
	footer := m.renderFooter(w)
	bodyHeight := max(1, m.height-lipgloss.Height(header)-lipgloss.Height(footer))

	var body []string
	cursorLine := -1
	switch {
	case m.connErr != nil:
		body = m.renderConnErr(w)
	case m.session == nil:
		body = []string{"", "  " + m.spin.View() + styleDim.Render(" Connecting to Rex…")}
	case m.view == viewHelp:
		body = m.renderHelp()
	case m.view == viewLog:
		body = m.renderLog(w)
		m.scroll = clamp(m.scroll, 0, max(0, len(body)-bodyHeight))
		body = body[m.scroll:]
	case m.view == viewClean:
		body = m.renderClean(w)
	default:
		body, cursorLine = m.renderHome(w)
	}

	if cursorLine >= 0 {
		// Keep the cursor visible, with a little context below it.
		if cursorLine < m.scroll {
			m.scroll = cursorLine
		}
		if cursorLine >= m.scroll+bodyHeight-1 {
			m.scroll = cursorLine - bodyHeight + 2
		}
		m.scroll = clamp(m.scroll, 0, max(0, len(body)-bodyHeight))
		body = body[m.scroll:]
	}
	if len(body) > bodyHeight {
		body = body[:bodyHeight]
	}
	for len(body) < bodyHeight {
		body = append(body, "")
	}
	return header + "\n" + strings.Join(body, "\n") + "\n" + footer
}

func (m *model) renderHeader(w int) string {
	title := styleTitle.Render("amber")
	if m.opts.Version != "" {
		title += " " + styleDim.Render(m.opts.Version)
	}
	buttons := []struct {
		label, key string
		active     bool
	}{
		{"Home", "H", m.view == viewHome},
		{"Install", "I", false},
		{"Update", "U", false},
		{"Restore", "R", false},
		{"Build", "B", false},
		{"Check", "C", false},
		{"Clean", "X", m.view == viewClean},
		{"Log", "L", m.view == viewLog},
		{"Help", "?", m.view == viewHelp},
	}
	var parts []string
	for _, b := range buttons {
		label := b.label + " (" + b.key + ")"
		if b.active {
			parts = append(parts, styleButtonActive.Render(label))
		} else {
			parts = append(parts, styleButton.Render(label))
		}
	}
	bar := wrapJoin(parts, " ", w-2)
	return "\n " + title + "\n\n " + strings.Join(bar, "\n ") + "\n"
}

// wrapJoin joins styled parts with sep, wrapping to width.
func wrapJoin(parts []string, sep string, width int) []string {
	var lines []string
	line := ""
	for _, p := range parts {
		switch {
		case line == "":
			line = p
		case lipgloss.Width(line)+lipgloss.Width(sep)+lipgloss.Width(p) > width:
			lines = append(lines, line)
			line = p
		default:
			line += sep + p
		}
	}
	return append(lines, line)
}

func (m *model) renderFooter(w int) string {
	var left string
	switch {
	case m.status != "" && m.statusErr:
		left = styleErr.Render(m.status)
	case m.status != "":
		left = styleOK.Render(m.status)
	case m.reloading:
		left = m.spin.View() + styleDim.Render(" Reloading Rex config…")
	}
	if m.reloading && m.status != "" {
		left = m.spin.View() + styleDim.Render(" Reloading Rex config…")
	}
	hints := styleFaint.Render("j/k move · enter details · u/i/r/b/c plugin · q quit")
	if m.view != viewHome {
		hints = styleFaint.Render("esc back · q close")
	}
	gap := w - 2 - lipgloss.Width(left) - lipgloss.Width(hints)
	if gap < 2 {
		return " " + truncate(left, w-2)
	}
	return " " + left + strings.Repeat(" ", gap) + hints
}

func (m *model) renderConnErr(w int) []string {
	lines := []string{"", "  " + styleErr.Render(iconFailed+" Cannot start Amber"), ""}
	for _, l := range wrap(m.connErr.Error(), w-6) {
		lines = append(lines, "    "+l)
	}
	return append(lines, "", "  "+styleDim.Render("Run `amber doctor` for a full check. Press q to quit."))
}

func (m *model) renderStats() string {
	total, loaded, installed := len(m.rows), 0, 0
	for _, r := range m.rows {
		if r.p.LoadStatus == "loaded" {
			loaded++
		}
		if r.hasState && r.state.Installed {
			installed++
		}
	}
	parts := []string{
		styleCount.Render("Total: ") + styleName.Render(fmt.Sprint(total)) + styleCount.Render(" plugins"),
		styleCount.Render("Installed: ") + styleName.Render(fmt.Sprint(installed)),
		styleCount.Render("Loaded: ") + styleName.Render(fmt.Sprint(loaded)),
	}
	if n := m.failures(); n > 0 {
		parts = append(parts, styleErr.Render(fmt.Sprintf("Failed: %d", n)))
	}
	if m.busy() {
		parts = append(parts, styleAccent.Render(fmt.Sprintf("Running: %d", m.running+len(m.queue))))
	}
	return "  " + strings.Join(parts, styleFaint.Render("  ·  "))
}

func (m *model) renderHome(w int) ([]string, int) {
	lines := []string{m.renderStats()}
	if root := m.session.Info.Root; root != "" {
		lines = append(lines, "  "+styleFaint.Render(root))
	}
	if len(m.rows) == 0 {
		return append(lines, "", "  "+styleDim.Render("No plugins declared. Add them to amber.setup{ plugins = { … } } in your Rex config.")), -1
	}
	cur := m.current()
	cursorLine := -1
	for _, s := range m.sections() {
		lines = append(lines, "", "  "+styleSection.Render(s.title)+styleCount.Render(fmt.Sprintf(" (%d)", len(s.rows))))
		for _, r := range s.rows {
			if r == cur {
				cursorLine = len(lines)
			}
			lines = append(lines, m.renderRow(r, r == cur, w))
			if r.expanded {
				lines = append(lines, m.renderDetails(r, w)...)
			}
		}
	}
	return lines, cursorLine
}

func (m *model) renderRow(r *row, selected bool, w int) string {
	icon, iconStyle := iconInstalled, styleOK
	switch {
	case r.task != nil:
		icon, iconStyle = m.spin.View(), lipgloss.NewStyle()
	case r.queued != OpNone:
		icon, iconStyle = "…", styleDim
	case r.err != nil:
		icon, iconStyle = iconFailed, styleErr
	case r.result != nil && changedStatus(r.result.Status):
		icon, iconStyle = iconUpdated, styleOK
	case r.check != nil && r.check.Outdated:
		icon, iconStyle = iconOutdated, styleWarn
	case !r.p.Enabled:
		icon, iconStyle = iconDisabled, styleFaint
	case r.p.LocalPath:
		icon, iconStyle = iconLocal, styleLocal
	case r.hasState && !r.state.Installed:
		icon, iconStyle = iconMissing, styleDim
	case r.hasState && attention(r) != "":
		icon, iconStyle = iconInstalled, styleWarn
	}

	prefix := "   "
	name := styleName.Render(r.p.Name)
	if selected {
		prefix = " " + styleCursor.Render(iconCursor) + " "
		name = styleCursor.Render(r.p.Name)
	}
	line := prefix + iconStyle.Render(icon) + " " + name
	detail := m.rowDetail(r)
	if detail != "" {
		line += "  " + detail
	}
	return truncate(line, w-1)
}

// rowDetail is the one-line summary right of the plugin name.
func (m *model) rowDetail(r *row) string {
	switch {
	case r.task != nil:
		text := styleAccent.Render(string(r.task.op)) + " " + styleDim.Render(r.task.stage)
		if r.task.progress >= 0 {
			text += " " + bar(r.task.progress, 12) + styleDim.Render(fmt.Sprintf(" %3.0f%%", r.task.progress*100))
		}
		if elapsed := time.Since(r.task.started); elapsed > 3*time.Second {
			text += styleFaint.Render(fmt.Sprintf("  %ds", int(elapsed.Seconds())))
		}
		return text
	case r.queued != OpNone:
		return styleDim.Render("waiting to " + string(r.queued))
	case r.err != nil:
		return styleErr.Render(string(r.errOp) + " failed: " + firstLine(r.err.Error()))
	case r.result != nil && changedStatus(r.result.Status):
		return resultDetail(r.result)
	case r.check != nil && r.check.Outdated:
		text := styleHash.Render(short(r.check.Current)) + styleDim.Render(" → ") + styleHash.Render(short(r.check.Target))
		if r.check.TargetRef != "" {
			text += " " + styleRef.Render(r.check.TargetRef)
		}
		if n := len(r.check.Commits); n > 0 {
			text += styleDim.Render(fmt.Sprintf("  %d new commit%s", n, plural(n)))
		}
		return text
	case !r.p.Enabled:
		return styleFaint.Render("disabled")
	case r.p.LocalPath:
		return styleFaint.Render(r.p.Dir)
	case !r.hasState:
		return ""
	case !r.state.Installed:
		return styleDim.Render("press i to install")
	}
	text := styleHash.Render(short(r.state.Head))
	if ref := firstNonEmpty(r.p.Version, r.state.Branch); ref != "" {
		text += " " + styleRef.Render(ref)
	}
	if r.check != nil && !r.check.Outdated {
		text += " " + styleOK.Render("up to date")
	}
	if len(r.p.Build) > 0 {
		text += " " + styleDim.Render(iconBuild)
	}
	if r.state.Dirty {
		text += " " + styleWarn.Render("modified")
	}
	if a := attention(r); a != "" {
		text += "  " + styleWarn.Render(a)
	}
	return text
}

func resultDetail(res *engine.Result) string {
	text := styleOK.Render(string(res.Status))
	if res.From != "" && res.From != res.To {
		text += " " + styleHash.Render(short(res.From)) + styleDim.Render(" → ") + styleHash.Render(short(res.To))
	} else if res.To != "" {
		text += " " + styleHash.Render(short(res.To))
	}
	if n := len(res.Commits); n > 0 {
		text += styleDim.Render(fmt.Sprintf("  %d commit%s", n, plural(n)))
	}
	if res.Built {
		text += " " + styleDim.Render(iconBuild+" built")
	}
	if res.Message != "" {
		text += "  " + styleDim.Render(res.Message)
	}
	return text
}

func (m *model) renderDetails(r *row, w int) []string {
	indent := "       "
	kv := func(k, v string) string {
		return indent + styleDim.Render(fmt.Sprintf("%-9s", k)) + " " + v
	}
	var lines []string
	if r.p.URL != "" && !r.p.LocalPath {
		lines = append(lines, kv("url", styleRef.Render(r.p.URL)))
	}
	lines = append(lines, kv("dir", r.p.Dir))
	if r.p.Subdir != "" {
		lines = append(lines, kv("subdir", r.p.Subdir))
	}
	lines = append(lines, kv("main", r.p.Main))
	if r.p.Version != "" {
		v := styleRef.Render(r.p.Version)
		if r.state.VersionRef != "" && r.state.VersionRef != r.p.Version {
			v += styleDim.Render(" → " + r.state.VersionRef)
		}
		lines = append(lines, kv("version", v))
	}
	if r.hasState && r.state.Installed {
		lines = append(lines, kv("commit", styleHash.Render(r.state.Head)))
		locked := styleFaint.Render("none")
		if r.state.Locked != "" {
			locked = styleHash.Render(r.state.Locked)
		}
		lines = append(lines, kv("locked", locked))
	}
	for i, step := range r.p.Build {
		label := ""
		if i == 0 {
			label = "build"
		}
		cmd := step.Command
		if step.Type != "shell" {
			cmd = styleDim.Render("Lua function")
		}
		lines = append(lines, kv(label, cmd))
	}
	status := r.p.LoadStatus
	if status == "" {
		status = "unknown"
	}
	statusStyle := styleDim
	if status == "loaded" {
		statusStyle = styleOK
	} else if status == "error" || status == "missing" || status == "unbuilt" {
		statusStyle = styleWarn
	}
	lines = append(lines, kv("load", statusStyle.Render(status)))
	if r.p.LoadError != "" {
		for _, l := range wrap(r.p.LoadError, w-20) {
			lines = append(lines, kv("", styleWarn.Render(l)))
		}
	}
	if r.err != nil {
		for i, l := range wrap(r.err.Error(), w-20) {
			label := ""
			if i == 0 {
				label = "error"
			}
			lines = append(lines, kv(label, styleErr.Render(l)))
		}
	}

	var commits []engine.Commit
	switch {
	case r.check != nil && r.check.Outdated:
		commits = r.check.Commits
	case r.result != nil:
		commits = r.result.Commits
	}
	if len(commits) > 0 {
		lines = append(lines, "")
		for i, c := range commits {
			if i == 10 {
				lines = append(lines, indent+styleFaint.Render(fmt.Sprintf("… %d more", len(commits)-10)))
				break
			}
			line := indent + styleHash.Render(short(c.Hash)) + " " + c.Subject
			if !c.When.IsZero() {
				line += styleFaint.Render(" (" + ago(c.When) + ")")
			}
			lines = append(lines, truncate(line, w-1))
		}
	}
	if n := len(r.log); n > 0 {
		lines = append(lines, "")
		for _, l := range r.log[max(0, n-8):] {
			lines = append(lines, truncate(indent+styleFaint.Render(l), w-1))
		}
	}
	return append(lines, "")
}

func (m *model) renderLog(w int) []string {
	var lines []string
	for _, d := range m.diags {
		style := styleWarn
		if d.Severity == "error" {
			style = styleErr
		}
		src := ""
		if d.Source != "" {
			src = styleDim.Render(d.Source + " ")
		}
		lines = append(lines, "  "+style.Render("rex "+d.Severity)+" "+src+d.Message)
	}
	for _, r := range m.rows {
		if len(r.log) == 0 && r.err == nil {
			continue
		}
		lines = append(lines, "", "  "+styleSection.Render(r.p.Name))
		for _, l := range r.log {
			lines = append(lines, truncate("    "+styleDim.Render(l), w-1))
		}
		if r.err != nil {
			for _, l := range wrap(r.err.Error(), w-6) {
				lines = append(lines, "    "+styleErr.Render(l))
			}
		}
	}
	if len(lines) == 0 {
		lines = []string{"", "  " + styleDim.Render("Nothing logged yet. Git and build output shows up here while plugins run.")}
	}
	return lines
}

func (m *model) renderHelp() []string {
	entry := func(key, text string) string {
		return "    " + styleKey.Render(fmt.Sprintf("%-10s", key)) + " " + text
	}
	return []string{
		"",
		"  " + styleSection.Render("All plugins"),
		entry("I", "install missing plugins (at the locked commit when there is one)"),
		entry("U", "update to the newest commit or version and rewrite the lockfile"),
		entry("R", "restore the commits recorded in the lockfile"),
		entry("B", "build plugins that declare a build step"),
		entry("C", "check for updates without changing anything"),
		entry("X", "clean leftover checkouts and lock directories"),
		"",
		"  " + styleSection.Render("Plugin under the cursor"),
		entry("i u r b c", "install, update, restore, build, check"),
		entry("enter", "show details, commits, and output"),
		"",
		"  " + styleSection.Render("Navigation"),
		entry("j k ↓ ↑", "move"),
		entry("g G", "first, last"),
		entry("L", "log of Git, build, and Rex reload output"),
		entry("esc", "back"),
		entry("q", "quit (twice while plugins run, which cancels them)"),
		"",
		"  " + styleDim.Render("Rex reloads its config after anything changes, so new plugin code takes effect at once."),
	}
}

func (m *model) renderClean(w int) []string {
	lines := []string{"", "  " + styleSection.Render("Clean")}
	switch {
	case m.cleanLoading:
		return append(lines, "", "  "+m.spin.View()+styleDim.Render(" Looking for leftovers…"))
	case m.cleanErr != nil:
		return append(lines, "", "  "+styleErr.Render(m.cleanErr.Error()), "", "  "+styleDim.Render("esc to go back"))
	case len(m.cleanItems) == 0:
		return append(lines, "", "  "+styleOK.Render("Nothing to clean."), "", "  "+styleDim.Render("esc to go back"))
	}
	lines = append(lines, "  "+styleDim.Render("These are not declared in your config or were left by an interrupted run:"), "")
	for _, it := range m.cleanItems {
		target := it.Path
		if it.Kind == engine.CleanLockEntry {
			target = it.Name + styleDim.Render(" in the lockfile")
		}
		lines = append(lines, truncate("    "+styleErr.Render(iconFailed)+" "+styleDim.Render(fmt.Sprintf("%-14s", it.Kind))+" "+target, w-1))
	}
	if m.cleaning {
		return append(lines, "", "  "+m.spin.View()+styleDim.Render(" Removing…"))
	}
	return append(lines, "",
		"  "+styleWarn.Render("Removing deletes these directories for good, including any local changes in them."),
		"  "+styleKey.Render("y")+" remove   "+styleKey.Render("esc")+" cancel")
}

func bar(progress float64, width int) string {
	filled := int(progress*float64(width) + 0.5)
	filled = clamp(filled, 0, width)
	return styleBarOn.Render(strings.Repeat("━", filled)) + styleBarOff.Render(strings.Repeat("━", width-filled))
}

func short(hash string) string {
	if len(hash) > 7 {
		return hash[:7]
	}
	return hash
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}

func clamp(v, lo, hi int) int {
	return max(lo, min(v, hi))
}

func truncate(s string, width int) string {
	if width <= 0 || lipgloss.Width(s) <= width {
		return s
	}
	return lipgloss.NewStyle().MaxWidth(width).Render(s)
}

// wrap splits plain text into lines of at most width cells.
func wrap(s string, width int) []string {
	if width < 10 {
		width = 10
	}
	var out []string
	for _, para := range strings.Split(strings.TrimSpace(s), "\n") {
		line := ""
		for _, word := range strings.Fields(para) {
			if line != "" && len(line)+1+len(word) > width {
				out = append(out, line)
				line = word
			} else if line == "" {
				line = word
			} else {
				line += " " + word
			}
		}
		out = append(out, line)
	}
	return out
}

func ago(t time.Time) string {
	d := time.Since(t)
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	case d < 60*24*time.Hour:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	}
	return t.Format("2006-01-02")
}
