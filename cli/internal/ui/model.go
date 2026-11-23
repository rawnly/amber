// Package ui is Amber's full-screen terminal interface, modelled on
// lazy.nvim's plugin window: plugins grouped by state, live per-plugin
// progress, and single-key operations.
package ui

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"charm.land/bubbles/v2/spinner"
	tea "charm.land/bubbletea/v2"

	"github.com/rawnly/amber/cli/internal/amber"
	"github.com/rawnly/amber/cli/internal/engine"
	"github.com/rawnly/amber/cli/internal/rex"
)

// Backend runs plugin operations; *engine.Engine implements it.
type Backend interface {
	Run(ctx context.Context, op engine.Op, p *amber.Plugin, emit engine.Emit) (engine.Result, error)
	Check(ctx context.Context, p *amber.Plugin, emit engine.Emit) (engine.Check, error)
	State(ctx context.Context, p *amber.Plugin) engine.State
	CleanPlan(ctx context.Context, withLockEntries bool) ([]engine.CleanItem, error)
	Clean(ctx context.Context, items []engine.CleanItem) error
}

// Session is a connected Amber configuration.
type Session struct {
	Info    *amber.Info
	Backend Backend
	// Reload reloads the Rex configuration; nil disables reloading.
	Reload func(context.Context) ([]rex.Diagnostic, error)
	// Refresh re-reads Amber's configuration, e.g. load statuses after a reload.
	Refresh func(context.Context) (*amber.Info, error)
}

// Op names an operation the UI can start.
type Op string

const (
	OpNone    Op = ""
	OpInstall Op = "install"
	OpUpdate  Op = "update"
	OpRestore Op = "restore"
	OpBuild   Op = "build"
	OpCheck   Op = "check"
	OpClean   Op = "clean"
)

// Options configure a UI run.
type Options struct {
	Connect   func(context.Context) (*Session, error)
	Op        Op     // operation to start once connected
	Target    string // plugin name for Op, or "" for all
	NoReload  bool   // don't reload Rex after changes
	CleanLock bool   // include lockfile entries of undeclared plugins in the clean plan
	Version   string
	// Parallel is how many plugins run at once; defaults to 4.
	Parallel int
}

type view int

const (
	viewHome view = iota
	viewLog
	viewHelp
	viewClean
)

type task struct {
	op       Op
	stage    string
	progress float64
	started  time.Time
}

type row struct {
	p        *amber.Plugin
	state    engine.State
	hasState bool
	task     *task
	queued   Op
	result   *engine.Result
	check    *engine.Check
	err      error
	errOp    Op
	log      []string
	expanded bool
}

type job struct {
	op   Op
	name string
}

// Messages.
type (
	connectedMsg struct {
		s   *Session
		err error
	}
	stateMsg struct {
		name  string
		state engine.State
	}
	eventMsg   engine.Event
	jobDoneMsg struct {
		job    job
		result engine.Result
		check  engine.Check
		err    error
	}
	cleanPlanMsg struct {
		items []engine.CleanItem
		err   error
	}
	cleanDoneMsg struct{ err error }
	reloadMsg    struct {
		diags []rex.Diagnostic
		info  *amber.Info
		err   error
	}
)

type model struct {
	opts   Options
	ctx    context.Context
	cancel context.CancelFunc

	session *Session
	connErr error
	rows    []*row
	byName  map[string]*row

	events  chan tea.Msg
	queue   []job
	running int
	changed bool // a finished job changed a checkout since the last reload

	view      view
	cursor    int
	scroll    int
	width     int
	height    int
	spin      spinner.Model
	status    string
	statusErr bool
	quitArmed bool

	cleanItems   []engine.CleanItem
	cleanErr     error
	cleanLoading bool
	cleaning     bool

	reloading bool
	diags     []rex.Diagnostic
}

func newModel(opts Options) *model {
	if opts.Parallel <= 0 {
		opts.Parallel = 4
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &model{
		opts:   opts,
		ctx:    ctx,
		cancel: cancel,
		byName: map[string]*row{},
		events: make(chan tea.Msg, 1024),
		spin:   spinner.New(spinner.WithSpinner(spinner.MiniDot), spinner.WithStyle(styleAccent)),
		width:  80,
		height: 24,
	}
}

func (m *model) Init() tea.Cmd {
	return tea.Batch(m.spin.Tick, m.connect(), m.listen())
}

func (m *model) connect() tea.Cmd {
	return func() tea.Msg {
		s, err := m.opts.Connect(m.ctx)
		return connectedMsg{s: s, err: err}
	}
}

// listen delivers engine events from worker goroutines.
func (m *model) listen() tea.Cmd {
	return func() tea.Msg { return <-m.events }
}

func (m *model) emit(op Op) engine.Emit {
	return func(e engine.Event) {
		if e.Line != "" && e.Stage == "" {
			select { // drop log lines rather than stall Git when the UI is busy
			case m.events <- eventMsg(e):
			default:
			}
			return
		}
		select {
		case m.events <- eventMsg(e):
		case <-m.ctx.Done():
		}
	}
}

func (m *model) loadState(r *row) tea.Cmd {
	p := r.p
	return func() tea.Msg {
		return stateMsg{name: p.Name, state: m.session.Backend.State(m.ctx, p)}
	}
}

// enqueue schedules op for the named plugins (or every eligible plugin) and
// returns the commands that start what fits in the parallel budget.
func (m *model) enqueue(op Op, names ...string) tea.Cmd {
	if m.session == nil {
		return nil
	}
	if op == OpClean {
		return m.openClean()
	}
	targets := names
	if len(targets) == 0 {
		for _, r := range m.rows {
			if eligible(op, r) {
				targets = append(targets, r.p.Name)
			}
		}
	}
	added := 0
	for _, name := range targets {
		r := m.byName[name]
		if r == nil || r.task != nil || r.queued != OpNone {
			continue
		}
		if !r.p.Managed() {
			m.setStatus(fmt.Sprintf("%s is %s; Amber does not manage it", name, unmanagedReason(r.p)), true)
			continue
		}
		r.queued = op
		r.err, r.errOp = nil, OpNone
		m.queue = append(m.queue, job{op: op, name: name})
		added++
	}
	if added == 0 && len(names) == 0 {
		m.setStatus(fmt.Sprintf("nothing to %s", op), false)
	}
	m.view = viewHome
	return m.startJobs()
}

func eligible(op Op, r *row) bool {
	if !r.p.Managed() {
		return false
	}
	switch op {
	case OpInstall:
		return !r.hasState || !r.state.Installed
	case OpBuild:
		return len(r.p.Build) > 0 && r.state.Installed
	case OpUpdate, OpCheck:
		return r.state.Installed
	case OpRestore:
		return r.state.Locked != ""
	}
	return true
}

func unmanagedReason(p *amber.Plugin) string {
	if !p.Enabled {
		return "disabled"
	}
	return "local"
}

func (m *model) startJobs() tea.Cmd {
	var cmds []tea.Cmd
	for m.running < m.opts.Parallel && len(m.queue) > 0 {
		j := m.queue[0]
		m.queue = m.queue[1:]
		r := m.byName[j.name]
		r.queued = OpNone
		r.task = &task{op: j.op, stage: "starting", progress: -1, started: time.Now()}
		r.log = append(r.log[:0], "")[:0]
		m.running++
		cmds = append(cmds, m.runJob(j, r.p))
	}
	return tea.Batch(cmds...)
}

func (m *model) runJob(j job, p *amber.Plugin) tea.Cmd {
	backend := m.session.Backend
	emit := m.emit(j.op)
	return func() tea.Msg {
		done := jobDoneMsg{job: j}
		if j.op == OpCheck {
			done.check, done.err = backend.Check(m.ctx, p, emit)
		} else {
			done.result, done.err = backend.Run(m.ctx, engine.Op(j.op), p, emit)
		}
		return done
	}
}

func (m *model) busy() bool { return m.running > 0 || len(m.queue) > 0 }

func (m *model) maybeReload() tea.Cmd {
	if m.busy() || !m.changed || m.opts.NoReload || m.session.Reload == nil || m.reloading {
		return nil
	}
	m.changed = false
	m.reloading = true
	s := m.session
	return func() tea.Msg {
		diags, err := s.Reload(m.ctx)
		var info *amber.Info
		if err == nil && s.Refresh != nil {
			info, _ = s.Refresh(m.ctx)
		}
		return reloadMsg{diags: diags, info: info, err: err}
	}
}

func (m *model) openClean() tea.Cmd {
	m.view = viewClean
	m.cleanItems, m.cleanErr, m.cleanLoading = nil, nil, true
	backend, withLock := m.session.Backend, m.opts.CleanLock
	return func() tea.Msg {
		items, err := backend.CleanPlan(m.ctx, withLock)
		return cleanPlanMsg{items: items, err: err}
	}
}

func (m *model) setStatus(text string, isErr bool) {
	m.status, m.statusErr = text, isErr
}

func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		return m, nil

	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spin, cmd = m.spin.Update(msg)
		return m, cmd

	case connectedMsg:
		if msg.err != nil {
			m.connErr = msg.err
			return m, nil
		}
		m.session = msg.s
		var cmds []tea.Cmd
		for i := range msg.s.Info.Plugins {
			p := &msg.s.Info.Plugins[i]
			r := &row{p: p}
			m.rows = append(m.rows, r)
			m.byName[p.Name] = r
			cmds = append(cmds, m.loadState(r))
		}
		if m.opts.Target != "" && m.byName[m.opts.Target] == nil {
			m.setStatus("unknown plugin: "+m.opts.Target, true)
			return m, tea.Batch(cmds...)
		}
		if m.opts.Op != OpNone {
			op, target := m.opts.Op, m.opts.Target
			// Start after the first states arrive so "all" filters are accurate.
			cmds = append(cmds, func() tea.Msg { return startMsg{op: op, target: target} })
		}
		return m, tea.Batch(cmds...)

	case startMsg:
		if !m.allStatesLoaded() {
			return m, tea.Tick(20*time.Millisecond, func(time.Time) tea.Msg { return msg })
		}
		if msg.target != "" {
			return m, m.enqueue(msg.op, msg.target)
		}
		return m, m.enqueue(msg.op)

	case stateMsg:
		if r := m.byName[msg.name]; r != nil {
			r.state, r.hasState = msg.state, true
		}
		return m, nil

	case eventMsg:
		if r := m.byName[msg.Plugin]; r != nil && r.task != nil {
			if msg.Stage != "" {
				r.task.stage = msg.Stage
				r.task.progress = msg.Progress
			} else if msg.Progress >= 0 {
				r.task.progress = msg.Progress
			}
			if msg.Line != "" {
				r.log = append(r.log, msg.Line)
				if len(r.log) > 400 {
					r.log = r.log[len(r.log)-400:]
				}
			}
		}
		return m, m.listen()

	case jobDoneMsg:
		m.running--
		r := m.byName[msg.job.name]
		r.task = nil
		if msg.err != nil {
			r.err, r.errOp = msg.err, msg.job.op
			if errors.Is(msg.err, context.Canceled) {
				r.err = errors.New("cancelled")
			}
		} else if msg.job.op == OpCheck {
			c := msg.check
			r.check = &c
		} else {
			res := msg.result
			r.result = &res
			r.check = nil
			if res.Status != engine.StatusSkipped && res.Status != engine.StatusUpToDate {
				m.changed = true
			}
		}
		cmds := []tea.Cmd{m.loadState(r), m.startJobs()}
		if !m.busy() {
			m.setStatus(m.summary(msg.job.op), m.failures() > 0)
			cmds = append(cmds, m.maybeReload())
		}
		return m, tea.Batch(cmds...)

	case reloadMsg:
		m.reloading = false
		m.diags = msg.diags
		if msg.err != nil {
			m.setStatus("Rex reload failed: "+msg.err.Error(), true)
		} else {
			if msg.info != nil {
				for _, p := range msg.info.Plugins {
					if r := m.byName[p.Name]; r != nil {
						r.p.LoadStatus, r.p.LoadError = p.LoadStatus, p.LoadError
					}
				}
			}
			text := "Reloaded Rex config"
			if m.status != "" {
				text = m.status + " · reloaded Rex config"
			}
			if n := len(msg.diags); n > 0 {
				text += fmt.Sprintf(" with %d problem(s); press L to read them", n)
			}
			m.setStatus(text, len(msg.diags) > 0 || m.failures() > 0)
		}
		return m, nil

	case cleanPlanMsg:
		m.cleanLoading = false
		m.cleanItems, m.cleanErr = msg.items, msg.err
		return m, nil

	case cleanDoneMsg:
		m.cleaning = false
		if msg.err != nil {
			m.cleanErr = msg.err
			return m, nil
		}
		m.setStatus(fmt.Sprintf("Removed %d item(s)", len(m.cleanItems)), false)
		m.cleanItems = nil
		m.view = viewHome
		var cmds []tea.Cmd
		for _, r := range m.rows {
			cmds = append(cmds, m.loadState(r))
		}
		return m, tea.Batch(cmds...)

	case tea.KeyPressMsg:
		return m, m.handleKey(msg)
	}
	return m, nil
}

type startMsg struct {
	op     Op
	target string
}

func (m *model) allStatesLoaded() bool {
	for _, r := range m.rows {
		if !r.hasState {
			return false
		}
	}
	return true
}

func (m *model) failures() int {
	n := 0
	for _, r := range m.rows {
		if r.err != nil {
			n++
		}
	}
	return n
}

func (m *model) summary(op Op) string {
	counts := map[string]int{}
	for _, r := range m.rows {
		switch {
		case r.err != nil:
			counts["failed"]++
		case op == OpCheck && r.check != nil && r.check.Outdated:
			counts["outdated"]++
		case op != OpCheck && r.result != nil && r.result.Status != engine.StatusSkipped && r.result.Status != engine.StatusUpToDate:
			counts[string(r.result.Status)]++
		}
	}
	if len(counts) == 0 {
		if op == OpCheck {
			return "Everything is up to date"
		}
		return "Done; nothing changed"
	}
	keys := make([]string, 0, len(counts))
	for k := range counts {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%d %s", counts[k], k))
	}
	return "Done: " + strings.Join(parts, ", ")
}

func (m *model) handleKey(msg tea.KeyPressMsg) tea.Cmd {
	key := msg.String()
	if key == "ctrl+c" {
		m.cancel()
		return tea.Quit
	}
	if key != "q" {
		m.quitArmed = false
	}

	if m.view == viewClean {
		switch key {
		case "y", "enter":
			if len(m.cleanItems) > 0 && !m.cleaning && !m.cleanLoading {
				m.cleaning = true
				items, backend := m.cleanItems, m.session.Backend
				return func() tea.Msg { return cleanDoneMsg{err: backend.Clean(m.ctx, items)} }
			}
		case "n", "esc", "q", "H":
			if !m.cleaning {
				m.view = viewHome
			}
		}
		return nil
	}

	switch key {
	case "q":
		if m.view != viewHome {
			m.view = viewHome
			return nil
		}
		if m.busy() && !m.quitArmed {
			m.quitArmed = true
			m.setStatus("Plugins are still running; press q again to cancel them and quit", true)
			return nil
		}
		m.cancel()
		return tea.Quit
	case "esc":
		if m.view != viewHome {
			m.view = viewHome
		} else if r := m.current(); r != nil && r.expanded {
			r.expanded = false
		}
		return nil
	case "H":
		m.view = viewHome
	case "L":
		m.view = toggle(m.view, viewLog)
		m.scroll = 0
	case "?":
		m.view = toggle(m.view, viewHelp)
	case "I":
		return m.enqueue(OpInstall)
	case "U":
		return m.enqueue(OpUpdate)
	case "R":
		return m.enqueue(OpRestore)
	case "B":
		return m.enqueue(OpBuild)
	case "C":
		return m.enqueue(OpCheck)
	case "X":
		return m.enqueue(OpClean)
	}

	if m.view == viewLog {
		switch key {
		case "j", "down":
			m.scroll++
		case "k", "up":
			m.scroll = max(0, m.scroll-1)
		case "g", "home":
			m.scroll = 0
		case "G", "end":
			m.scroll = 1 << 30
		}
		return nil
	}
	if m.view != viewHome {
		return nil
	}

	order := m.order()
	switch key {
	case "j", "down":
		m.cursor = min(m.cursor+1, max(0, len(order)-1))
	case "k", "up":
		m.cursor = max(0, m.cursor-1)
	case "g", "home":
		m.cursor = 0
	case "G", "end":
		m.cursor = max(0, len(order)-1)
	case "enter", "space", "tab":
		if r := m.current(); r != nil {
			r.expanded = !r.expanded
		}
	case "i", "u", "r", "b", "c":
		if r := m.current(); r != nil {
			op := map[string]Op{"i": OpInstall, "u": OpUpdate, "r": OpRestore, "b": OpBuild, "c": OpCheck}[key]
			return m.enqueue(op, r.p.Name)
		}
	}
	return nil
}

func toggle(current, target view) view {
	if current == target {
		return viewHome
	}
	return target
}

// current is the plugin under the cursor in the home view.
func (m *model) current() *row {
	order := m.order()
	if len(order) == 0 {
		return nil
	}
	m.cursor = min(m.cursor, len(order)-1)
	return order[m.cursor]
}
