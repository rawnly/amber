package engine

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"time"

	"github.com/rawnly/amber/cli/internal/amber"
)

// buildTimeout bounds one shell build step.
const buildTimeout = 30 * time.Minute

// build runs the plugin's build steps for the locked commit and records it.
// A failure leaves the plugin recorded but unbuilt, so it can be retried.
func (e *Engine) build(ctx context.Context, p *amber.Plugin, commit string, rep reporter) error {
	head, err := revParse(ctx, p.Dir, "HEAD")
	if err != nil {
		return fmt.Errorf("cannot read checkout commit for build: %w", err)
	}
	if head != commit {
		return errors.New("checkout differs from lockfile; run amber restore before building")
	}

	if p.HasLuaBuild() {
		// Lua steps only run inside Rex; the action runs every step and
		// records the build itself.
		if e.Rex == nil {
			return errors.New("this plugin has a Lua build step, which needs a Rex connection")
		}
		rep.stage("building in Rex")
		actx, cancel := context.WithTimeout(ctx, 40*time.Second)
		defer cancel()
		return e.Rex.Action(actx, amber.Action, amber.BuildArgs(p.Name), nil)
	}

	env := append(os.Environ(),
		"AMBER_PLUGIN_NAME="+p.Name,
		"AMBER_PLUGIN_DIR="+p.Dir,
		"AMBER_PLUGIN_MODULE_DIR="+p.ModuleDir,
	)
	if p.DataDir != "" {
		env = append(env, "AMBER_PLUGIN_DATA_DIR="+p.DataDir)
	}
	for i, step := range p.Build {
		rep.stage(fmt.Sprintf("building %d/%d", i+1, len(p.Build)))
		if err := runStep(ctx, p.ModuleDir, step.Command, env, rep); err != nil {
			return fmt.Errorf("build step %d failed: %w", i+1, err)
		}
	}

	rep.stage("recording")
	return transaction(e.Info.Lockfile, func(l *lockData) (bool, error) {
		entry, ok := l.Plugins[p.Name]
		if !ok || entry.Commit != commit {
			return false, errors.New("lockfile changed during the build; run amber build again")
		}
		if entry.Built == commit {
			return false, nil
		}
		entry.Built = commit
		l.Plugins[p.Name] = entry
		return true, nil
	})
}

func runStep(ctx context.Context, dir, command string, env []string, rep reporter) error {
	ctx, cancel := context.WithTimeout(ctx, buildTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "sh", "-c", command)
	cmd.Dir = dir
	cmd.Env = env
	cmd.WaitDelay = waitDelay
	last := &tail{}
	o := rep.output()
	line := o.line
	o.line = func(s string) { last.add(s); line(s) }
	o.progress = nil
	w, wait := o.writer()
	cmd.Stdout, cmd.Stderr = w, w
	err := cmd.Run()
	wait()
	if err == nil {
		return nil
	}
	if ctx.Err() == context.DeadlineExceeded {
		return fmt.Errorf("timed out after %s", buildTimeout)
	}
	if out := last.String(); out != "" {
		return fmt.Errorf("%w\n%s", err, out)
	}
	return err
}
