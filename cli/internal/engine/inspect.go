package engine

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/rawnly/amber/cli/internal/amber"
)

func (e *Engine) check(ctx context.Context, p *amber.Plugin, emit Emit) (Check, error) {
	c := Check{Plugin: p.Name}
	if !p.Managed() {
		return c, ErrNotManaged
	}
	if !installed(p.Dir) {
		return c, errors.New("not installed; run amber install")
	}
	if emit == nil {
		emit = func(Event) {}
	}
	rep := reporter{plugin: p.Name, op: "check", emit: emit}
	head, err := revParse(ctx, p.Dir, "HEAD")
	if err != nil {
		return c, err
	}
	c.Current = head

	rep.stage("fetching")
	if _, err := git(ctx, gitCall{dir: p.Dir, network: true, out: rep.output()}, "fetch", "--progress", "--tags", "origin"); err != nil {
		return c, err
	}
	ref, err := e.updateTarget(ctx, p)
	if err != nil {
		return c, err
	}
	c.TargetRef = strings.TrimPrefix(ref, "refs/remotes/")
	if c.Target, err = revParse(ctx, p.Dir, ref); err != nil {
		return c, err
	}
	if c.Target != head {
		ahead, err := gitOK(ctx, p.Dir, "merge-base", "--is-ancestor", head, c.Target)
		if err != nil {
			return c, err
		}
		c.Outdated = ahead
		if ahead {
			c.Commits = commitsBetween(ctx, p.Dir, head, c.Target)
		}
	}
	return c, nil
}

// updateTarget is the ref an update would move to, from what was fetched.
func (e *Engine) updateTarget(ctx context.Context, p *amber.Plugin) (string, error) {
	if p.Version != "" {
		return resolveVersion(ctx, p.Dir, p.Version)
	}
	branch, err := currentBranch(ctx, p.Dir)
	if err != nil {
		return "", err
	}
	if branch != "" {
		upstream, err := git(ctx, gitCall{dir: p.Dir}, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
		if err != nil {
			return "", fmt.Errorf("branch %s has no upstream: %w", branch, err)
		}
		return upstream, nil
	}
	return originDefault(ctx, p.Dir)
}

func (e *Engine) state(ctx context.Context, p *amber.Plugin) State {
	st := State{Plugin: p.Name}
	if p.LocalPath {
		_, err := os.Stat(p.Dir)
		st.Installed = err == nil
		return st
	}
	if lock, err := readLock(e.Info.Lockfile); err != nil {
		st.Err = err
	} else if entry, ok := lock.Plugins[p.Name]; ok {
		st.Locked, st.LockedVersion, st.Built = entry.Commit, entry.Version, entry.Built
	}
	st.NeedsBuild = len(p.Build) > 0 && st.Locked != "" && st.Built != st.Locked
	if !installed(p.Dir) {
		return st
	}
	st.Installed = true
	var err error
	if st.Head, err = revParse(ctx, p.Dir, "HEAD"); err != nil && st.Err == nil {
		st.Err = err
	}
	st.Branch, _ = currentBranch(ctx, p.Dir)
	st.Dirty, _ = isDirty(ctx, p.Dir)
	if p.Version != "" {
		if ref, err := resolveVersion(ctx, p.Dir, p.Version); err == nil {
			st.VersionRef = ref
			if target, err := revParse(ctx, p.Dir, ref); err == nil && st.Head != "" {
				matches := target == st.Head
				st.VersionMatches = &matches
			}
		}
	}
	return st
}

var tempName = regexp.MustCompile(`^\.amber-[A-Za-z0-9]{8}$`)

// declared is every managed install location and plugin name in the config,
// enabled or not.
func (e *Engine) declared() (dirs, names map[string]bool) {
	dirs, names = map[string]bool{}, map[string]bool{}
	for _, p := range e.Info.Plugins {
		names[p.Name] = true
		// Local plugins count too: one may live under Root and hold unpushed work.
		dirs[filepath.Clean(p.Dir)] = true
	}
	return dirs, names
}

// classify says whether path, inside root/<owner>/, is something Clean may
// remove; it never follows symlinks.
func (e *Engine) classify(path string, dirs map[string]bool) (CleanKind, bool) {
	fi, err := os.Lstat(path)
	if err != nil || !fi.IsDir() {
		return "", false
	}
	name := filepath.Base(path)
	switch {
	case tempName.MatchString(name):
		return CleanTemp, true
	case strings.HasSuffix(name, ".amber-lock"):
		return CleanInstallLock, true
	case dirs[filepath.Clean(path)]:
		return "", false
	case installed(path):
		return CleanOrphan, true
	}
	return "", false
}

func (e *Engine) within(path string) bool {
	rel, err := filepath.Rel(e.Info.Root, path)
	return err == nil && rel != "." && !strings.HasPrefix(rel, "..") && strings.Count(rel, string(filepath.Separator)) == 1
}

func (e *Engine) cleanPlan(withLockEntries bool) ([]CleanItem, error) {
	var items []CleanItem
	dirs, names := e.declared()
	owners, err := os.ReadDir(e.Info.Root)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	for _, owner := range owners {
		if !owner.IsDir() || owner.Type()&os.ModeSymlink != 0 {
			continue
		}
		entries, err := os.ReadDir(filepath.Join(e.Info.Root, owner.Name()))
		if err != nil {
			continue
		}
		for _, entry := range entries {
			path := filepath.Join(e.Info.Root, owner.Name(), entry.Name())
			if kind, ok := e.classify(path, dirs); ok {
				item := CleanItem{Kind: kind, Path: path}
				if kind == CleanOrphan {
					item.Name = owner.Name() + "/" + entry.Name()
				}
				items = append(items, item)
			}
		}
	}
	if fi, err := os.Lstat(e.Info.Lockfile + ".lock"); err == nil && fi.IsDir() {
		items = append(items, CleanItem{Kind: CleanLockfileGuard, Path: e.Info.Lockfile + ".lock"})
	}
	if withLockEntries {
		lock, err := readLock(e.Info.Lockfile)
		if err != nil {
			return items, err
		}
		for name := range lock.Plugins {
			if !names[name] {
				items = append(items, CleanItem{Kind: CleanLockEntry, Name: name})
			}
		}
	}
	return items, nil
}

func (e *Engine) clean(items []CleanItem) error {
	dirs, names := e.declared()
	var errs []error
	var entries []string
	for _, it := range items {
		switch it.Kind {
		case CleanLockEntry:
			if !names[it.Name] {
				entries = append(entries, it.Name)
			}
			continue
		case CleanLockfileGuard:
			if it.Path != e.Info.Lockfile+".lock" {
				errs = append(errs, fmt.Errorf("refusing to remove %s: not the lockfile guard", it.Path))
				continue
			}
			if err := os.Remove(it.Path); err != nil && !errors.Is(err, os.ErrNotExist) {
				errs = append(errs, err)
			}
			continue
		}
		kind, ok := e.classify(it.Path, dirs)
		if !ok || kind != it.Kind || !e.within(it.Path) {
			errs = append(errs, fmt.Errorf("refusing to remove %s: it is no longer a %s", it.Path, it.Kind))
			continue
		}
		if err := os.RemoveAll(it.Path); err != nil {
			errs = append(errs, err)
		}
	}
	if len(entries) > 0 {
		err := transaction(e.Info.Lockfile, func(l *lockData) (bool, error) {
			for _, name := range entries {
				delete(l.Plugins, name)
			}
			return true, nil
		})
		if err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}
