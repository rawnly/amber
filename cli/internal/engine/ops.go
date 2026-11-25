package engine

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/rawnly/amber/cli/internal/amber"
)

// reporter sends events for one plugin operation.
type reporter struct {
	plugin string
	op     Op
	emit   Emit
}

func (r reporter) stage(s string) {
	r.emit(Event{Plugin: r.plugin, Op: r.op, Stage: s, Progress: -1})
}

// output streams command output as log lines and progress.
func (r reporter) output() output {
	return output{
		line:     func(s string) { r.emit(Event{Plugin: r.plugin, Op: r.op, Progress: -1, Line: s}) },
		progress: func(p float64) { r.emit(Event{Plugin: r.plugin, Op: r.op, Progress: p}) },
	}
}

// acquire takes the per-plugin guard `<dir>.amber-lock`, which keeps two
// Amber processes from working on one checkout at once.
func acquire(p *amber.Plugin) (func(), error) {
	if err := os.MkdirAll(p.Parent, 0o755); err != nil {
		return nil, err
	}
	guard := p.Dir + ".amber-lock"
	if err := os.Mkdir(guard, 0o755); err != nil {
		if errors.Is(err, os.ErrExist) {
			return nil, fmt.Errorf("plugin is busy: %s; if no Amber command is running, remove it (amber clean does)", guard)
		}
		return nil, err
	}
	return func() { os.Remove(guard) }, nil
}

func (e *Engine) run(ctx context.Context, op Op, p *amber.Plugin, emit Emit) (Result, error) {
	res := Result{Plugin: p.Name, Op: op}
	if !p.Managed() {
		return res, ErrNotManaged
	}
	if emit == nil {
		emit = func(Event) {}
	}
	rep := reporter{plugin: p.Name, op: op, emit: emit}
	lock, err := readLock(e.Info.Lockfile)
	if err != nil {
		return res, err
	}
	entry, hasEntry := lock.Plugins[p.Name]
	present := installed(p.Dir)

	switch op {
	case OpBuild:
		if !present {
			return res, errors.New("not installed; run amber install")
		}
		if len(p.Build) == 0 {
			res.Status, res.Message = StatusSkipped, "no build step"
			return res, nil
		}
		if !hasEntry {
			return res, errors.New("no lockfile entry; run amber install")
		}
	case OpInstall:
		if present {
			res.Status, res.Message = StatusSkipped, "already installed"
			if hasEntry && (len(p.Build) == 0 || entry.Built == entry.Commit) {
				res.To = entry.Commit
				return res, nil
			}
		}
	case OpUpdate:
		if !present {
			return res, errors.New("not installed; run amber install")
		}
	case OpRestore:
		if !hasEntry {
			return res, fmt.Errorf("no lockfile entry for %s; run amber install", p.Name)
		}
	default:
		return res, fmt.Errorf("unknown operation %q", op)
	}

	release, err := acquire(p)
	if err != nil {
		return res, err
	}
	defer release()

	switch {
	case op == OpInstall && !present:
		locked := ""
		if hasEntry {
			locked = entry.Commit
		}
		if err := e.install(ctx, p, locked, rep); err != nil {
			return res, err
		}
		res.Status = StatusInstalled
	case op == OpRestore && !present:
		if err := e.install(ctx, p, entry.Commit, rep); err != nil {
			return res, err
		}
		res.Status, res.Message = StatusRestored, "installed the locked commit"
	case op == OpRestore:
		res.From, _ = revParse(ctx, p.Dir, "HEAD")
		if res.From == entry.Commit {
			res.Status = StatusUpToDate
			break
		}
		if dirty, err := isDirty(ctx, p.Dir); err != nil {
			return res, err
		} else if dirty {
			return res, errors.New("working tree is not clean; refusing to restore")
		}
		// The lockfile may come from a machine that updated past this clone.
		if _, err := revParse(ctx, p.Dir, entry.Commit); err != nil {
			rep.stage("fetching")
			if _, err := git(ctx, gitCall{dir: p.Dir, network: true, out: rep.output()}, "fetch", "--progress", "--tags", "origin"); err != nil {
				return res, err
			}
		}
		rep.stage("checking out")
		if _, err := git(ctx, gitCall{dir: p.Dir}, "checkout", "--detach", entry.Commit, "--"); err != nil {
			return res, err
		}
		res.Status = StatusRestored
	case op == OpUpdate:
		res.From, _ = revParse(ctx, p.Dir, "HEAD")
		if err := e.update(ctx, p, rep); err != nil {
			return res, err
		}
	}

	head, err := revParse(ctx, p.Dir, "HEAD")
	if err != nil {
		return res, fmt.Errorf("cannot read checkout commit: %w", err)
	}
	res.To = head
	if op == OpUpdate {
		res.Status = StatusUpdated
		if res.From == head {
			res.Status = StatusUpToDate
		}
	}

	// Record the checkout: an update always rewrites the entry, an install
	// only creates a missing one. The lock stays authoritative otherwise.
	var locked lockEntry
	err = transaction(e.Info.Lockfile, func(l *lockData) (bool, error) {
		current, exists := l.Plugins[p.Name]
		switch {
		case op == OpUpdate:
			next := lockEntry{Commit: head, Version: p.Version}
			if exists && current.Commit == head {
				next.Built = current.Built // a new commit invalidates the build
			}
			l.Plugins[p.Name] = next
			locked = next
			return !exists || next != current, nil
		case !exists && (op == OpInstall):
			locked = lockEntry{Commit: head, Version: p.Version}
			l.Plugins[p.Name] = locked
			return true, nil
		case !exists:
			return false, fmt.Errorf("no lockfile entry for %s; run amber install", p.Name)
		}
		locked = current
		return false, nil
	})
	if err != nil {
		if op == OpUpdate || res.Status == StatusInstalled {
			return res, fmt.Errorf("checkout succeeded but the lockfile was not updated: %w", err)
		}
		return res, err
	}
	res.Commits = commitsBetween(ctx, p.Dir, res.From, res.To)

	// The build always targets the locked commit, never whatever HEAD is.
	if len(p.Build) > 0 && (op == OpBuild || locked.Built != locked.Commit) {
		if err := e.build(ctx, p, locked.Commit, rep); err != nil {
			return res, err
		}
		res.Built = true
		if op == OpBuild || res.Status == StatusSkipped {
			res.Status, res.Message = StatusBuilt, ""
		}
	}
	return res, nil
}

// install clones into a unique sibling directory, checks out the locked
// commit or the requested version, and moves the result into place without
// replacing anything. A failed install leaves nothing behind.
func (e *Engine) install(ctx context.Context, p *amber.Plugin, locked string, rep reporter) error {
	if _, err := os.Lstat(p.Dir); err == nil {
		return fmt.Errorf("destination already exists but is not a Git checkout: %s", p.Dir)
	}
	tmp := filepath.Join(p.Parent, ".amber-"+randomName(8))
	if err := os.Mkdir(tmp, 0o755); err != nil {
		return err
	}
	ok := false
	defer func() {
		if !ok {
			os.RemoveAll(tmp)
		}
	}()
	rep.stage("cloning")
	if _, err := git(ctx, gitCall{dir: p.Parent, network: true, out: rep.output()}, "clone", "--progress", "--", p.URL, tmp); err != nil {
		return err
	}
	if locked != "" || p.Version != "" {
		rep.stage("checking out")
		ref := locked
		if ref == "" {
			var err error
			if ref, err = resolveVersion(ctx, tmp, p.Version); err != nil {
				return err
			}
		}
		if _, err := git(ctx, gitCall{dir: tmp}, "checkout", "--detach", ref, "--"); err != nil {
			return err
		}
	}
	if err := renameExclusive(tmp, p.Dir); err != nil {
		if errors.Is(err, os.ErrExist) {
			return errors.New("destination appeared during installation")
		}
		return err
	}
	ok = true
	return nil
}

func (e *Engine) update(ctx context.Context, p *amber.Plugin, rep reporter) error {
	dir := p.Dir
	if p.Version != "" {
		rep.stage("fetching")
		if _, err := git(ctx, gitCall{dir: dir, network: true, out: rep.output()}, "fetch", "--progress", "--tags", "origin"); err != nil {
			return err
		}
		ref, err := resolveVersion(ctx, dir, p.Version)
		if err != nil {
			return err
		}
		rep.stage("checking out")
		_, err = git(ctx, gitCall{dir: dir}, "checkout", "--detach", ref, "--")
		return err
	}
	branch, err := currentBranch(ctx, dir)
	if err != nil {
		return err
	}
	if branch != "" {
		rep.stage("pulling")
		_, err := git(ctx, gitCall{dir: dir, network: true, out: rep.output()}, "pull", "--progress", "--ff-only")
		return err
	}
	// Detached and unversioned, e.g. after a restore: advance to the origin
	// default branch, but only when that loses nothing.
	if dirty, err := isDirty(ctx, dir); err != nil {
		return err
	} else if dirty {
		return errors.New("working tree is not clean; refusing to update detached checkout")
	}
	rep.stage("fetching")
	if _, err := git(ctx, gitCall{dir: dir, network: true, out: rep.output()}, "fetch", "--progress", "origin"); err != nil {
		return err
	}
	ref, err := originDefault(ctx, dir)
	if err != nil {
		return err
	}
	if ok, err := gitOK(ctx, dir, "merge-base", "--is-ancestor", "HEAD", ref); err != nil || !ok {
		if err == nil {
			err = fmt.Errorf("HEAD is not an ancestor of %s", strings.TrimPrefix(ref, "refs/remotes/"))
		}
		return fmt.Errorf("cannot fast-forward detached checkout: %w", err)
	}
	rep.stage("checking out")
	_, err = git(ctx, gitCall{dir: dir}, "checkout", "--detach", ref, "--")
	return err
}

func originDefault(ctx context.Context, dir string) (string, error) {
	ref, err := git(ctx, gitCall{dir: dir}, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD")
	if err != nil || ref == "" {
		return "", fmt.Errorf("cannot determine origin default branch: %v", err)
	}
	if !strings.HasPrefix(ref, "refs/remotes/origin/") {
		return "", errors.New("invalid origin default branch")
	}
	return ref, nil
}

const nameAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

func randomName(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	for i := range b {
		b[i] = nameAlphabet[int(b[i])%len(nameAlphabet)]
	}
	return string(b)
}

func renameChecked(from, to string) error {
	if _, err := os.Lstat(to); err == nil {
		return os.ErrExist
	}
	return os.Rename(from, to)
}
