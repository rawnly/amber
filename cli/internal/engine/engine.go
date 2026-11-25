// Package engine installs, updates, restores, builds, checks, and cleans
// managed plugins on the local machine. It is the Go port of the Git and
// lockfile logic that used to live in amber/git.lua and amber.lua, and it
// keeps their safety rules: never reset local changes, refuse dirty restores
// and detached updates, write the lockfile atomically under its `.lock` guard,
// and treat the lock entry as authoritative until an explicit update.
//
// All methods are safe to call concurrently for different plugins. Callers in
// the UI run several plugins at once.
package engine

import (
	"context"
	"errors"
	"time"

	"github.com/rawnly/amber/cli/internal/amber"
)

// Op is an operation on one plugin.
type Op string

const (
	OpInstall Op = "install" // clone missing checkouts; use the locked commit if any
	OpUpdate  Op = "update"  // move to the newest commit/version and rewrite the lock entry
	OpRestore Op = "restore" // check out the locked commit; install it when missing
	OpBuild   Op = "build"   // run the build steps for the locked commit, even if already built
)

// Status is how an operation ended.
type Status string

const (
	StatusInstalled Status = "installed"
	StatusUpdated   Status = "updated"
	StatusUpToDate  Status = "up to date"
	StatusRestored  Status = "restored"
	StatusBuilt     Status = "built"
	StatusSkipped   Status = "skipped" // nothing to do, e.g. already installed or no build step; Result.Message says why
)

// Event reports progress while an operation runs. Emit callbacks may be
// called from several goroutines.
type Event struct {
	Plugin string
	Op     Op
	// Stage is a short present-tense label: "cloning", "fetching",
	// "checking out", "building 1/2", "recording".
	Stage string
	// Progress is 0..1 when Git reports a percentage, otherwise -1.
	Progress float64
	// Line is one raw line of Git or build output, for the log view. Empty
	// for pure stage changes.
	Line string
}

// Emit receives events. It must not block for long.
type Emit func(Event)

// Commit is one commit in a range.
type Commit struct {
	Hash    string
	Subject string
	Author  string
	When    time.Time
}

// Result is the outcome of a successful operation.
type Result struct {
	Plugin  string
	Op      Op
	Status  Status
	Message string   // short human summary, e.g. "already installed"
	From    string   // commit before; empty for a fresh install
	To      string   // commit after (the locked commit)
	Commits []Commit // From..To, newest first, at most 50; empty when not applicable
	Built   bool     // a build ran and was recorded
}

// Check is the result of looking for a newer commit or version.
type Check struct {
	Plugin    string
	Current   string   // HEAD commit
	Target    string   // commit an update would move to
	TargetRef string   // e.g. "v1.4.0" or "origin/main"
	Commits   []Commit // Current..Target, newest first, at most 50
	Outdated  bool     // Target differs from Current and is ahead of it
}

// State is what can be learned about a plugin without the network.
type State struct {
	Plugin         string
	Installed      bool
	Head           string // checked-out commit
	Branch         string // current branch, or "" when detached
	Dirty          bool   // tracked or untracked changes (git status --porcelain --untracked-files=normal)
	Locked         string // lock entry commit, if any
	LockedVersion  string // version recorded in the lock entry
	Built          string // lock entry built commit, if any
	NeedsBuild     bool   // the plugin has build steps and Built != Locked
	VersionRef     string // local resolution of plugin.Version, when set
	VersionMatches *bool  // HEAD equals VersionRef's commit; nil when unknown
	Err            error  // problem reading state; other fields are best effort
}

// CleanKind says why a path is safe to remove.
type CleanKind string

const (
	CleanOrphan        CleanKind = "orphan"         // checkout under root that no spec (enabled or disabled) declares
	CleanTemp          CleanKind = "temp"           // leftover .amber-XXXXXXXX clone directory
	CleanInstallLock   CleanKind = "install lock"   // leftover <dir>.amber-lock directory
	CleanLockfileGuard CleanKind = "lockfile guard" // leftover <lockfile>.lock directory
	CleanLockEntry     CleanKind = "lock entry"     // lockfile entry for an undeclared plugin (only when asked)
)

// CleanItem is one thing Clean can remove.
type CleanItem struct {
	Kind CleanKind
	Path string // absolute path; empty for CleanLockEntry
	Name string // plugin name for CleanOrphan and CleanLockEntry
}

// ErrNotManaged is returned for local or disabled plugins.
var ErrNotManaged = errors.New("plugin is not managed by Amber (local or disabled)")

// Engine runs operations for one Amber configuration.
type Engine struct {
	Info *amber.Info
	// Rex runs Lua build steps through amber.LuaBuildAction. May be nil when
	// no plugin has a Lua build step.
	Rex amber.Actions
}

// New returns an engine for info.
func New(info *amber.Info, rex amber.Actions) *Engine {
	return &Engine{Info: info, Rex: rex}
}

// Run performs op on one managed plugin, then runs a pending build: after
// install, update, or restore when the lock entry's built commit differs from
// its commit; always for OpBuild.
func (e *Engine) Run(ctx context.Context, op Op, p *amber.Plugin, emit Emit) (Result, error) {
	return e.run(ctx, op, p, emit)
}

// Check fetches from origin (no checkout, no lockfile change) and reports
// whether an update would move the plugin.
func (e *Engine) Check(ctx context.Context, p *amber.Plugin, emit Emit) (Check, error) {
	return e.check(ctx, p, emit)
}

// State reads local state without touching the network.
func (e *Engine) State(ctx context.Context, p *amber.Plugin) State {
	return e.state(ctx, p)
}

// CleanPlan lists what Clean would remove. Lock entries for undeclared
// plugins are included only when withLockEntries is true. It never lists a
// declared plugin's checkout (local plugins included) or anything outside Root and
// the lockfile's directory.
func (e *Engine) CleanPlan(ctx context.Context, withLockEntries bool) ([]CleanItem, error) {
	return e.cleanPlan(withLockEntries)
}

// Clean removes items, re-checking each one just before removal.
func (e *Engine) Clean(ctx context.Context, items []CleanItem) error {
	return e.clean(items)
}
