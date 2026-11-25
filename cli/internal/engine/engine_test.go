package engine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rawnly/amber/cli/internal/amber"
)

func TestMain(m *testing.M) {
	// Isolate Git from the developer's configuration.
	os.Setenv("GIT_CONFIG_GLOBAL", os.DevNull)
	os.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	for k, v := range map[string]string{
		"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
		"GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
	} {
		os.Setenv(k, v)
	}
	os.Exit(m.Run())
}

func run(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

// origin is a bare repository with a working clone to commit from.
type origin struct {
	t    *testing.T
	bare string
	work string
}

func newOrigin(t *testing.T, name string) *origin {
	t.Helper()
	base := t.TempDir()
	o := &origin{t: t, bare: filepath.Join(base, name+".git"), work: filepath.Join(base, name+"-work")}
	run(t, base, "init", "-q", "--bare", "-b", "main", o.bare)
	run(t, base, "clone", "-q", o.bare, o.work)
	run(t, o.work, "checkout", "-q", "-b", "main")
	o.commit("initial")
	return o
}

func (o *origin) commit(msg string) string {
	o.t.Helper()
	os.WriteFile(filepath.Join(o.work, "file.txt"), []byte(msg), 0o644)
	run(o.t, o.work, "add", ".")
	run(o.t, o.work, "commit", "-q", "-m", msg)
	run(o.t, o.work, "push", "-q", "origin", "HEAD:main")
	return run(o.t, o.work, "rev-parse", "HEAD")
}

func (o *origin) tag(name string) string {
	o.t.Helper()
	run(o.t, o.work, "tag", name)
	run(o.t, o.work, "push", "-q", "origin", name)
	return run(o.t, o.work, "rev-parse", "HEAD")
}

type fixture struct {
	t      *testing.T
	root   string
	engine *Engine
}

func newFixture(t *testing.T) *fixture {
	root := t.TempDir()
	info := &amber.Info{Root: filepath.Join(root, "plugins"), Lockfile: filepath.Join(root, "config", "amber-lock.json")}
	return &fixture{t: t, root: root, engine: New(info, nil)}
}

func (f *fixture) plugin(name string, o *origin, mutate ...func(*amber.Plugin)) *amber.Plugin {
	owner, repo, _ := strings.Cut(name, "/")
	p := amber.Plugin{
		Name: name, Slug: name, URL: o.bare, Main: repo, Enabled: true,
		Dir:    filepath.Join(f.engine.Info.Root, owner, repo),
		Parent: filepath.Join(f.engine.Info.Root, owner),
	}
	p.ModuleDir = p.Dir
	for _, m := range mutate {
		m(&p)
	}
	f.engine.Info.Plugins = append(f.engine.Info.Plugins, p)
	return &f.engine.Info.Plugins[len(f.engine.Info.Plugins)-1]
}

func (f *fixture) do(op Op, p *amber.Plugin) (Result, error) {
	return f.engine.Run(context.Background(), op, p, nil)
}

func (f *fixture) must(op Op, p *amber.Plugin) Result {
	f.t.Helper()
	res, err := f.do(op, p)
	if err != nil {
		f.t.Fatalf("%s %s: %v", op, p.Name, err)
	}
	return res
}

func (f *fixture) lock() *lockData {
	f.t.Helper()
	l, err := readLock(f.engine.Info.Lockfile)
	if err != nil {
		f.t.Fatal(err)
	}
	return l
}

func (f *fixture) head(p *amber.Plugin) string {
	return run(f.t, p.Dir, "rev-parse", "HEAD")
}

func wantErr(t *testing.T, err error, substr string) {
	t.Helper()
	if err == nil || !strings.Contains(err.Error(), substr) {
		t.Fatalf("want error containing %q, got %v", substr, err)
	}
}

func TestBestTag(t *testing.T) {
	tags := []string{"v1.2.0", "v1.4.0", "1.4.7", "v2.0.0", "v0.1.2", "v0.1.9", "v0.2.0", "v0.0.3", "v0.0.4", "v1.5.0-rc1", "junk"}
	cases := map[string]string{
		"^1.2.0": "1.4.7", "~1.2.0": "v1.2.0", "~1.4.0": "1.4.7", "^2.0.0": "v2.0.0",
		"^0.1.0": "v0.1.9", "^0.0.3": "v0.0.3", "~0.1.5": "v0.1.9",
	}
	for version, want := range cases {
		got, ok, err := bestTag(version, tags)
		if !ok || err != nil || got != want {
			t.Errorf("%s: got %q %v %v, want %q", version, got, ok, err, want)
		}
	}
	if _, _, err := bestTag("^3.0.0", tags); err == nil {
		t.Error("^3.0.0 should match nothing")
	}
	if _, ok, _ := bestTag("v1.2.0", tags); ok {
		t.Error("an exact tag is not a range")
	}
}

func TestInstallRecordsLockAndSkipsInstalled(t *testing.T) {
	f, o := newFixture(t), newOrigin(t, "a")
	p := f.plugin("alice/a", o)
	res := f.must(OpInstall, p)
	if res.Status != StatusInstalled || res.To != f.head(p) {
		t.Fatalf("unexpected result %+v", res)
	}
	if got := f.lock().Plugins[p.Name].Commit; got != res.To {
		t.Fatalf("lock = %s, want %s", got, res.To)
	}
	if res := f.must(OpInstall, p); res.Status != StatusSkipped {
		t.Fatalf("second install: %+v", res)
	}
	if _, err := os.Stat(p.Dir + ".amber-lock"); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("install guard left behind")
	}
}

func TestInstallUsesLockedCommitDespiteVersion(t *testing.T) {
	f, o := newFixture(t), newOrigin(t, "a")
	first := o.tag("v1.0.0")
	o.commit("second")
	o.tag("v1.1.0")
	p := f.plugin("alice/a", o, func(p *amber.Plugin) { p.Version = "^1.0.0" })
	writeLockFile(t, f.engine.Info.Lockfile, map[string]lockEntry{p.Name: {Commit: first, Version: "v1.0.0"}})
	f.must(OpInstall, p)
	if f.head(p) != first {
		t.Fatal("install ignored the locked commit")
	}
	if got := f.lock().Plugins[p.Name]; got.Commit != first || got.Version != "v1.0.0" {
		t.Fatalf("install replaced the lock entry: %+v", got)
	}
}

func TestInstallResolvesRange(t *testing.T) {
	f, o := newFixture(t), newOrigin(t, "a")
	o.tag("v1.0.0")
	o.commit("two")
	want := o.tag("v1.3.0")
	o.commit("three")
	o.tag("v2.0.0")
	p := f.plugin("alice/a", o, func(p *amber.Plugin) { p.Version = "^1.0.0" })
	f.must(OpInstall, p)
	if f.head(p) != want {
		t.Fatal("did not check out the highest matching tag")
	}
}

func TestInstallFailureCleansUp(t *testing.T) {
	f := newFixture(t)
	o := &origin{bare: filepath.Join(t.TempDir(), "missing.git")}
	p := f.plugin("alice/gone", o)
	_, err := f.do(OpInstall, p)
	if err == nil {
		t.Fatal("clone of a missing repository succeeded")
	}
	entries, _ := os.ReadDir(p.Parent)
	if len(entries) != 0 {
		t.Fatalf("left behind: %v", entries)
	}
}

func TestInstallRefusesNonCheckout(t *testing.T) {
	f, o := newFixture(t), newOrigin(t, "a")
	p := f.plugin("alice/a", o)
	os.MkdirAll(p.Dir, 0o755)
	_, err := f.do(OpInstall, p)
	wantErr(t, err, "not a Git checkout")
}

func TestUpdateBranchFastForwards(t *testing.T) {
	f, o := newFixture(t), newOrigin(t, "a")
	p := f.plugin("alice/a", o)
	first := f.must(OpInstall, p).To
	next := o.commit("second")
	res := f.must(OpUpdate, p)
	if res.Status != StatusUpdated || res.From != first || res.To != next || len(res.Commits) != 1 || res.Commits[0].Subject != "second" {
		t.Fatalf("unexpected result %+v", res)
	}
	if f.lock().Plugins[p.Name].Commit != next {
		t.Fatal("update did not rewrite the lock entry")
	}
	if res := f.must(OpUpdate, p); res.Status != StatusUpToDate {
		t.Fatalf("second update: %+v", res)
	}
}

func TestUpdateVersionedMovesToNewerTag(t *testing.T) {
	f, o := newFixture(t), newOrigin(t, "a")
	o.tag("v1.0.0")
	p := f.plugin("alice/a", o, func(p *amber.Plugin) { p.Version = "^1.0.0" })
	f.must(OpInstall, p)
	o.commit("feature")
	want := o.tag("v1.1.0")
	res := f.must(OpUpdate, p)
	if res.To != want || f.lock().Plugins[p.Name].Version != "^1.0.0" {
		t.Fatalf("unexpected result %+v / %+v", res, f.lock().Plugins[p.Name])
	}
}

func TestUpdateDetached(t *testing.T) {
	f, o := newFixture(t), newOrigin(t, "a")
	p := f.plugin("alice/a", o)
	f.must(OpInstall, p)
	run(t, p.Dir, "checkout", "-q", "--detach", "HEAD")
	next := o.commit("second")

	os.WriteFile(filepath.Join(p.Dir, "scratch"), []byte("x"), 0o644)
	_, err := f.do(OpUpdate, p)
	wantErr(t, err, "not clean")
	os.Remove(filepath.Join(p.Dir, "scratch"))

	if res := f.must(OpUpdate, p); res.To != next {
		t.Fatalf("detached update: %+v", res)
	}
}

func TestRestore(t *testing.T) {
	f, o := newFixture(t), newOrigin(t, "a")
	p := f.plugin("alice/a", o)
	first := f.must(OpInstall, p).To
	o.commit("second")
	f.must(OpUpdate, p)
	writeLockFile(t, f.engine.Info.Lockfile, map[string]lockEntry{p.Name: {Commit: first}})

	os.WriteFile(filepath.Join(p.Dir, "file.txt"), []byte("local edit"), 0o644)
	_, err := f.do(OpRestore, p)
	wantErr(t, err, "not clean")
	run(t, p.Dir, "checkout", "-q", "--", "file.txt")

	if res := f.must(OpRestore, p); res.Status != StatusRestored || f.head(p) != first {
		t.Fatalf("restore: %+v", res)
	}
	os.RemoveAll(p.Dir)
	if res := f.must(OpRestore, p); res.Status != StatusRestored || f.head(p) != first {
		t.Fatalf("restore of a missing checkout: %+v", res)
	}
}

func TestRestoreFetchesMissingCommit(t *testing.T) {
	f, o := newFixture(t), newOrigin(t, "a")
	p := f.plugin("alice/a", o)
	f.must(OpInstall, p)
	newer := o.commit("pushed from another machine")
	writeLockFile(t, f.engine.Info.Lockfile, map[string]lockEntry{p.Name: {Commit: newer}})
	if res := f.must(OpRestore, p); res.Status != StatusRestored || f.head(p) != newer {
		t.Fatalf("restore: %+v", res)
	}
}

func TestRestoreNeedsLockEntry(t *testing.T) {
	f, o := newFixture(t), newOrigin(t, "a")
	p := f.plugin("alice/a", o)
	_, err := f.do(OpRestore, p)
	wantErr(t, err, "no lockfile entry")
}

func TestMalformedLockIsNeverOverwritten(t *testing.T) {
	f, o := newFixture(t), newOrigin(t, "a")
	p := f.plugin("alice/a", o)
	os.MkdirAll(filepath.Dir(f.engine.Info.Lockfile), 0o755)
	bad := `{"format":1,"plugins":{"x/y":{"commit":"nothex"}}}`
	os.WriteFile(f.engine.Info.Lockfile, []byte(bad), 0o644)
	_, err := f.do(OpInstall, p)
	wantErr(t, err, "invalid lockfile entry")
	if data, _ := os.ReadFile(f.engine.Info.Lockfile); string(data) != bad {
		t.Fatal("malformed lockfile was rewritten")
	}
}

func TestLockPreservesUnrelatedEntriesAndFormat(t *testing.T) {
	f, o := newFixture(t), newOrigin(t, "a")
	p := f.plugin("alice/a", o)
	other := strings.Repeat("c", 40)
	writeLockFile(t, f.engine.Info.Lockfile, map[string]lockEntry{"bob/b": {Commit: other, Version: "v1"}})
	res := f.must(OpInstall, p)
	data, _ := os.ReadFile(f.engine.Info.Lockfile)
	want := fmt.Sprintf("{\n  \"format\": 1,\n  \"plugins\": {\n    \"alice/a\": {\n      \"commit\": %q\n    },\n    \"bob/b\": {\n      \"commit\": %q,\n      \"version\": \"v1\"\n    }\n  }\n}\n", res.To, other)
	if string(data) != want {
		t.Fatalf("lockfile:\n%s\nwant:\n%s", data, want)
	}
}

func TestLockAcceptsEmptyLuaArray(t *testing.T) {
	path := filepath.Join(t.TempDir(), "lock.json")
	os.WriteFile(path, []byte(`{"format":1,"plugins":[]}`), 0o644)
	if l, err := readLock(path); err != nil || len(l.Plugins) != 0 {
		t.Fatalf("got %v %v", l, err)
	}
}

func TestLockGuardBusy(t *testing.T) {
	defer func(old time.Duration) { lockWait = old }(lockWait)
	lockWait = 100 * time.Millisecond
	path := filepath.Join(t.TempDir(), "lock.json")
	os.Mkdir(path+".lock", 0o755)
	err := transaction(path, func(*lockData) (bool, error) { return true, nil })
	wantErr(t, err, "lockfile is busy")
}

func TestBuild(t *testing.T) {
	f, o := newFixture(t), newOrigin(t, "a")
	marker := filepath.Join(t.TempDir(), "built")
	fail := filepath.Join(t.TempDir(), "fail")
	p := f.plugin("alice/a", o, func(p *amber.Plugin) {
		p.Build = []amber.BuildStep{
			{Type: amber.BuildShell, Command: `test ! -e "` + fail + `" || { echo exploded >&2; exit 3; }`},
			{Type: amber.BuildShell, Command: `echo "$AMBER_PLUGIN_NAME $(pwd)" > "` + marker + `"`},
		}
	})

	os.WriteFile(fail, nil, 0o644)
	_, err := f.do(OpInstall, p)
	wantErr(t, err, "build step 1 failed")
	wantErr(t, err, "exploded")
	entry := f.lock().Plugins[p.Name]
	if entry.Commit == "" || entry.Built != "" {
		t.Fatalf("a failed build must leave the plugin recorded and unbuilt: %+v", entry)
	}
	if st := f.engine.State(context.Background(), p); !st.NeedsBuild {
		t.Fatal("state should report the pending build")
	}

	os.Remove(fail)
	res := f.must(OpInstall, p)
	if !res.Built || f.lock().Plugins[p.Name].Built != entry.Commit {
		t.Fatalf("retry did not build: %+v", res)
	}
	data, _ := os.ReadFile(marker)
	if got := strings.TrimSpace(string(data)); !strings.HasPrefix(got, "alice/a ") || !strings.HasSuffix(got, filepath.Base(p.Dir)) {
		t.Fatalf("build ran with %q", got)
	}

	// An update to the same commit keeps the build; a new commit drops and redoes it.
	if res := f.must(OpUpdate, p); res.Built {
		t.Fatal("rebuilt an unchanged commit")
	}
	next := o.commit("second")
	if res := f.must(OpUpdate, p); !res.Built || f.lock().Plugins[p.Name].Built != next {
		t.Fatalf("new commit was not rebuilt: %+v", res)
	}
	if res := f.must(OpBuild, p); res.Status != StatusBuilt {
		t.Fatalf("forced build: %+v", res)
	}
}

func TestBuildRefusesDrift(t *testing.T) {
	f, o := newFixture(t), newOrigin(t, "a")
	p := f.plugin("alice/a", o, func(p *amber.Plugin) {
		p.Build = []amber.BuildStep{{Type: amber.BuildShell, Command: "true"}}
	})
	f.must(OpInstall, p)
	o.commit("second")
	run(t, p.Dir, "pull", "-q", "--ff-only")
	_, err := f.do(OpBuild, p)
	wantErr(t, err, "differs from lockfile")
}

type fakeRex struct {
	mu    sync.Mutex
	calls []string
}

func (r *fakeRex) Action(_ context.Context, name string, args map[string]any, _ any) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls = append(r.calls, fmt.Sprintf("%s %v", name, args["plugin"]))
	return nil
}

func TestLuaBuildRunsInRex(t *testing.T) {
	f, o := newFixture(t), newOrigin(t, "a")
	rex := &fakeRex{}
	f.engine.Rex = rex
	p := f.plugin("alice/a", o, func(p *amber.Plugin) {
		p.Build = []amber.BuildStep{{Type: amber.BuildShell, Command: "false"}, {Type: amber.BuildLua}}
	})
	if res := f.must(OpInstall, p); !res.Built {
		t.Fatalf("not built: %+v", res)
	}
	if len(rex.calls) != 1 || rex.calls[0] != amber.LuaBuildAction+" alice/a" {
		t.Fatalf("calls = %v", rex.calls)
	}
}

func TestConcurrentRunsRecordEveryPlugin(t *testing.T) {
	f := newFixture(t)
	for i := range 4 {
		f.plugin(fmt.Sprintf("alice/p%d", i), newOrigin(t, fmt.Sprint(i)))
	}
	var wg sync.WaitGroup
	errs := make([]error, 4)
	for i := range 4 {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, errs[i] = f.engine.Run(context.Background(), OpInstall, &f.engine.Info.Plugins[i], nil)
		}(i)
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Fatalf("plugin %d: %v", i, err)
		}
	}
	if n := len(f.lock().Plugins); n != 4 {
		t.Fatalf("lock has %d entries, want 4", n)
	}
}

func TestCheck(t *testing.T) {
	f, o := newFixture(t), newOrigin(t, "a")
	p := f.plugin("alice/a", o)
	f.must(OpInstall, p)
	c, err := f.engine.Check(context.Background(), p, nil)
	if err != nil || c.Outdated {
		t.Fatalf("fresh install: %+v %v", c, err)
	}
	next := o.commit("second")
	c, err = f.engine.Check(context.Background(), p, nil)
	if err != nil || !c.Outdated || c.Target != next || len(c.Commits) != 1 || c.TargetRef != "origin/main" {
		t.Fatalf("after a new commit: %+v %v", c, err)
	}
	if f.head(p) == next {
		t.Fatal("check moved the checkout")
	}
}

func TestProgressEvents(t *testing.T) {
	f, o := newFixture(t), newOrigin(t, "a")
	p := f.plugin("alice/a", o)
	var mu sync.Mutex
	stages := map[string]bool{}
	_, err := f.engine.Run(context.Background(), OpInstall, p, func(e Event) {
		mu.Lock()
		defer mu.Unlock()
		if e.Plugin != p.Name || e.Op != OpInstall {
			t.Errorf("event for %s/%s", e.Plugin, e.Op)
		}
		if e.Stage != "" {
			stages[e.Stage] = true
		}
	})
	if err != nil || !stages["cloning"] {
		t.Fatalf("stages %v, err %v", stages, err)
	}
}

func TestClean(t *testing.T) {
	f, o := newFixture(t), newOrigin(t, "a")
	kept := f.plugin("alice/a", o)
	disabled := f.plugin("alice/off", newOrigin(t, "off"), func(p *amber.Plugin) { p.Enabled = false })
	f.must(OpInstall, kept)
	// A disabled plugin's checkout is declared too, so clean must keep it.
	run(t, t.TempDir(), "clone", "-q", o.bare, disabled.Dir)
	orphan := filepath.Join(f.engine.Info.Root, "alice", "orphan")
	run(t, t.TempDir(), "clone", "-q", o.bare, orphan)
	// A local path plugin stored under Root must never be cleaned.
	local := filepath.Join(f.engine.Info.Root, "alice", "local")
	run(t, t.TempDir(), "clone", "-q", o.bare, local)
	f.plugin("alice/local", o, func(p *amber.Plugin) { p.LocalPath, p.Dir = true, local })
	temp := filepath.Join(f.engine.Info.Root, "alice", ".amber-AbCd1234")
	guard := filepath.Join(f.engine.Info.Root, "alice", "x.amber-lock")
	notGit := filepath.Join(f.engine.Info.Root, "alice", "notes")
	for _, d := range []string{temp, guard, notGit, f.engine.Info.Lockfile + ".lock"} {
		os.MkdirAll(d, 0o755)
	}
	writeLockFile(t, f.engine.Info.Lockfile, map[string]lockEntry{
		kept.Name: f.lock().Plugins[kept.Name], "gone/plugin": {Commit: strings.Repeat("d", 40)},
	})

	items, err := f.engine.CleanPlan(context.Background(), true)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]CleanKind{}
	for _, it := range items {
		got[it.Path+it.Name] = it.Kind
	}
	want := map[string]CleanKind{
		orphan + "alice/orphan":          CleanOrphan,
		temp:                             CleanTemp,
		guard:                            CleanInstallLock,
		f.engine.Info.Lockfile + ".lock": CleanLockfileGuard,
		"gone/plugin":                    CleanLockEntry,
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("plan:\n%v\nwant:\n%v", got, want)
	}
	if err := f.engine.Clean(context.Background(), items); err != nil {
		t.Fatal(err)
	}
	for _, d := range []string{orphan, temp, guard} {
		if _, err := os.Stat(d); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("%s still exists", d)
		}
	}
	for _, d := range []string{kept.Dir, disabled.Dir, notGit, local} {
		if _, err := os.Stat(d); err != nil {
			t.Errorf("%s was removed", d)
		}
	}
	if _, ok := f.lock().Plugins["gone/plugin"]; ok {
		t.Error("undeclared lock entry kept")
	}
	if _, ok := f.lock().Plugins[kept.Name]; !ok {
		t.Error("declared lock entry removed")
	}
}

func writeLockFile(t *testing.T, path string, entries map[string]lockEntry) {
	t.Helper()
	os.MkdirAll(filepath.Dir(path), 0o755)
	data, _ := json.Marshal(lockData{Format: 1, Plugins: entries})
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
}
