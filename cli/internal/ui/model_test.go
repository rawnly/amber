package ui

import (
	"context"
	"errors"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"charm.land/bubbles/v2/spinner"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"

	"github.com/rawnly/amber/cli/internal/amber"
	"github.com/rawnly/amber/cli/internal/engine"
	"github.com/rawnly/amber/cli/internal/rex"
)

type fakeBackend struct {
	mu   sync.Mutex
	runs []string
	fail map[string]bool
}

func (f *fakeBackend) Run(_ context.Context, op engine.Op, p *amber.Plugin, emit engine.Emit) (engine.Result, error) {
	f.mu.Lock()
	f.runs = append(f.runs, string(op)+" "+p.Name)
	f.mu.Unlock()
	emit(engine.Event{Plugin: p.Name, Op: op, Stage: "fetching", Progress: 0.5})
	emit(engine.Event{Plugin: p.Name, Op: op, Progress: -1, Line: "From github.com:" + p.Name})
	if f.fail[p.Name] {
		return engine.Result{}, errors.New("not possible to fast-forward, aborting")
	}
	return engine.Result{Plugin: p.Name, Op: op, Status: engine.StatusUpdated,
		From: strings.Repeat("a", 40), To: strings.Repeat("b", 40),
		Commits: []engine.Commit{{Hash: strings.Repeat("b", 40), Subject: "fix: resize", When: time.Now().Add(-2 * time.Hour)}}}, nil
}

func (f *fakeBackend) Check(context.Context, *amber.Plugin, engine.Emit) (engine.Check, error) {
	return engine.Check{}, nil
}

func (f *fakeBackend) State(_ context.Context, p *amber.Plugin) engine.State {
	return engine.State{Plugin: p.Name, Installed: p.Name != "rawnly/pooh", Head: strings.Repeat("9", 40),
		Locked: strings.Repeat("9", 40), Branch: "main"}
}

func (f *fakeBackend) CleanPlan(context.Context, bool) ([]engine.CleanItem, error) { return nil, nil }
func (f *fakeBackend) Clean(context.Context, []engine.CleanItem) error             { return nil }

func testSession(b *fakeBackend) *Session {
	reloads := 0
	return &Session{
		Info: &amber.Info{Root: "/plugins", Plugins: []amber.Plugin{
			{Name: "rawnly/bracco", Enabled: true, Version: "feature/rex_plugin", LoadStatus: "loaded"},
			{Name: "rawnly/sex", Enabled: true, LoadStatus: "loaded", Build: []amber.BuildStep{{Type: "shell", Command: "make"}}},
			{Name: "rawnly/pooh", Enabled: true, LoadStatus: "missing"},
			{Name: "me/dev", Enabled: true, LocalPath: true, Dir: "/src/dev", LoadStatus: "loaded"},
			{Name: "old/thing", Enabled: false},
		}},
		Backend: b,
		Reload: func(context.Context) ([]rex.Diagnostic, error) {
			reloads++
			return nil, nil
		},
	}
}

// drive feeds msg to the model and runs the resulting commands until the
// model settles, like the Bubble Tea runtime would.
func drive(t *testing.T, m *model, msg tea.Msg) {
	t.Helper()
	queue := []tea.Msg{msg}
	for steps := 0; len(queue) > 0; steps++ {
		if steps > 500 {
			t.Fatal("model did not settle")
		}
		next := queue[0]
		queue = queue[1:]
		_, cmd := m.Update(next)
		queue = append(queue, runCmd(m, cmd)...)
	}
}

func runCmd(m *model, cmd tea.Cmd) []tea.Msg {
	if cmd == nil {
		return nil
	}
	// Commands that block (the event listener, timers) are dropped after a
	// moment; the test delivers events itself.
	done := make(chan tea.Msg, 1)
	go func() { done <- cmd() }()
	var msg tea.Msg
	select {
	case msg = <-done:
	case <-time.After(100 * time.Millisecond):
		return nil
	}
	switch msg := msg.(type) {
	case tea.BatchMsg:
		var out []tea.Msg
		for _, c := range msg {
			out = append(out, runCmd(m, c)...)
		}
		return out
	case nil, spinner.TickMsg:
		return nil
	}
	return []tea.Msg{msg}
}

func newTestModel(b *fakeBackend, op Op) *model {
	m := newModel(Options{Connect: func(context.Context) (*Session, error) { return testSession(b), nil }, Op: op, Version: "v0.2.0"})
	m.width, m.height = 110, 40
	return m
}

func TestUpdateAllShowsResultsAndReloads(t *testing.T) {
	b := &fakeBackend{fail: map[string]bool{"rawnly/sex": true}}
	m := newTestModel(b, OpUpdate)
	drive(t, m, connectedMsg{s: testSession(b)})
	// Events arrive on the channel; deliver what was sent.
	for len(m.events) > 0 {
		drive(t, m, <-m.events)
	}
	if len(b.runs) != 2 { // installed managed plugins only
		t.Fatalf("runs = %v", b.runs)
	}
	out := ansi.Strip(m.render())
	for _, want := range []string{"Failed (1)", "Updated (1)", "rawnly/sex", "not possible to fast-forward", "aaaaaaa → bbbbbbb", "Not installed (1)", "Local (1)", "Disabled (1)"} {
		if !strings.Contains(out, want) {
			t.Errorf("render is missing %q", want)
		}
	}
	if m.failures() != 1 || m.busy() {
		t.Fatalf("failures=%d busy=%v", m.failures(), m.busy())
	}
	if os.Getenv("AMBER_UI_SNAPSHOT") != "" {
		os.WriteFile(os.Getenv("AMBER_UI_SNAPSHOT"), []byte(m.render()), 0o644)
	}
}

func TestKeysRunOnePlugin(t *testing.T) {
	b := &fakeBackend{}
	m := newTestModel(b, OpNone)
	drive(t, m, connectedMsg{s: testSession(b)})
	m.cursor = 0
	target := m.current().p.Name
	drive(t, m, tea.KeyPressMsg{Code: 'u', Text: "u"})
	if len(b.runs) != 1 || b.runs[0] != "update "+target {
		t.Fatalf("runs = %v", b.runs)
	}
	drive(t, m, tea.KeyPressMsg{Code: tea.KeyEnter})
	if !m.current().expanded {
		t.Fatal("enter did not expand the plugin")
	}
	if !strings.Contains(ansi.Strip(m.render()), "fix: resize") {
		t.Fatal("details do not list the new commits")
	}
}

func TestRenderFitsWidth(t *testing.T) {
	b := &fakeBackend{}
	m := newTestModel(b, OpNone)
	m.width = 60
	drive(t, m, connectedMsg{s: testSession(b)})
	for i, line := range strings.Split(m.render(), "\n") {
		if w := lipgloss.Width(line); w > 60 {
			t.Errorf("line %d is %d cells wide: %q", i, w, line)
		}
	}
}

// slowBackend holds a job until cancelled, then takes a moment to clean up.
type slowBackend struct {
	fakeBackend
	started  chan struct{}
	finished bool
}

func (s *slowBackend) Run(ctx context.Context, _ engine.Op, _ *amber.Plugin, _ engine.Emit) (engine.Result, error) {
	close(s.started)
	<-ctx.Done()
	time.Sleep(50 * time.Millisecond)
	s.finished = true
	return engine.Result{}, ctx.Err()
}

func TestStopWaitsForRunningJobs(t *testing.T) {
	b := &slowBackend{started: make(chan struct{})}
	m := newModel(Options{})
	m.session = &Session{Info: &amber.Info{}, Backend: b}
	p := &amber.Plugin{Name: "a/b"}
	go m.runJob(job{op: OpUpdate, name: p.Name}, p)()
	<-b.started
	m.stop()
	if !b.finished {
		t.Fatal("stop returned before the running job cleaned up")
	}
	if msg := m.runJob(job{op: OpUpdate, name: p.Name}, p)().(jobDoneMsg); msg.err == nil {
		t.Fatal("a job started after stop ran")
	}
}
