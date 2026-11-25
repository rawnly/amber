// Package amber holds the configuration Amber's Lua library reports through
// the amber action's info operation: where things live and every normalized plugin spec.
package amber

import (
	"context"
	"encoding/json"
	"fmt"
)

// Action is the one Lua action the command calls. Without `op` it opens the
// window; with one it runs a data operation and returns its result.
const Action = "amber"

// InfoArgs asks for Info.
var InfoArgs = map[string]any{"op": "info"}

// BuildArgs runs a plugin's Lua build steps on the server and records the
// build in the lockfile. It fails with the step's error.
func BuildArgs(plugin string) map[string]any {
	return map[string]any{"op": "build", "plugin": plugin}
}

// Info is the result of the info operation.
type Info struct {
	Version   string   `json:"version"`    // Lua library version
	Dir       string   `json:"dir"`        // Lua library directory (where amber.lua lives)
	Root      string   `json:"root"`       // managed plugin root
	Lockfile  string   `json:"lockfile"`   // absolute lockfile path
	StateRoot string   `json:"state_root"` // parent of per-plugin data dirs; may be empty
	Plugins   []Plugin `json:"plugins"`    // declaration order
	// LockError is set when the Lua side could not read the lockfile.
	LockError string `json:"lock_error,omitempty"`
}

// Plugin is one normalized plugin spec, as amber/spec.lua produces it.
type Plugin struct {
	Name       string      `json:"name"` // owner/repo or owner/repo@subdir
	Slug       string      `json:"slug"` // owner/repo or owner/repo--subdir
	URL        string      `json:"url"`
	Dir        string      `json:"dir"` // checkout (or local path)
	ModuleDir  string      `json:"module_dir"`
	Parent     string      `json:"parent"` // <root>/<owner>
	Subdir     string      `json:"subdir,omitempty"`
	Main       string      `json:"main"`
	Version    string      `json:"version,omitempty"`
	Enabled    bool        `json:"enabled"`
	LocalPath  bool        `json:"local_path"`
	DataDir    string      `json:"data_dir,omitempty"`
	Build      []BuildStep `json:"build,omitempty"`
	LoadStatus string      `json:"load_status,omitempty"` // loaded, missing, error, unbuilt, disabled, not loaded
	LoadError  string      `json:"load_error,omitempty"`
}

// Managed reports whether Amber installs and updates this plugin.
func (p *Plugin) Managed() bool { return p.Enabled && !p.LocalPath }

// HasLuaBuild reports whether any build step is a Lua function, which only
// the server can run (through BuildArgs).
func (p *Plugin) HasLuaBuild() bool {
	for _, step := range p.Build {
		if step.Type == BuildLua {
			return true
		}
	}
	return false
}

// Build step types.
const (
	BuildShell = "shell"
	BuildLua   = "lua"
)

// BuildStep is a shell command, or a marker for a Lua function step.
type BuildStep struct {
	Type    string `json:"type"`
	Command string `json:"command,omitempty"`
}

// UnmarshalJSON accepts `{}` for an empty plugin list, since Lua cannot tell
// an empty array from an empty object.
func (i *Info) UnmarshalJSON(data []byte) error {
	type raw Info
	var aux struct {
		raw
		Plugins json.RawMessage `json:"plugins"`
	}
	if err := json.Unmarshal(data, &aux); err != nil {
		return err
	}
	*i = Info(aux.raw)
	i.Plugins = nil
	if len(aux.Plugins) == 0 || string(aux.Plugins) == "{}" || string(aux.Plugins) == "null" {
		return nil
	}
	return json.Unmarshal(aux.Plugins, &i.Plugins)
}

// UnmarshalJSON accepts `{}` for an empty build list.
func (p *Plugin) UnmarshalJSON(data []byte) error {
	type raw Plugin
	var aux struct {
		raw
		Build json.RawMessage `json:"build"`
	}
	if err := json.Unmarshal(data, &aux); err != nil {
		return err
	}
	*p = Plugin(aux.raw)
	p.Build = nil
	if len(aux.Build) == 0 || string(aux.Build) == "{}" || string(aux.Build) == "null" {
		return nil
	}
	return json.Unmarshal(aux.Build, &p.Build)
}

// Find returns the plugin with this name.
func (i *Info) Find(name string) (*Plugin, bool) {
	for idx := range i.Plugins {
		if i.Plugins[idx].Name == name {
			return &i.Plugins[idx], true
		}
	}
	return nil, false
}

// Actions is the part of the Rex client Amber needs to call Lua actions.
type Actions interface {
	Action(ctx context.Context, name string, args map[string]any, result any) error
}

// Fetch asks the Lua library for its configuration.
func Fetch(ctx context.Context, rex Actions) (*Info, error) {
	var info Info
	const mismatch = "is Amber loaded by your Rex config, and does the library match this command? Run amber self-update (or brew upgrade amber-rex)"
	if err := rex.Action(ctx, Action, InfoArgs, &info); err != nil {
		return nil, fmt.Errorf("cannot read Amber's configuration from Rex: %w; %s", err, mismatch)
	}
	// A library from before the op argument ignores it and answers with the
	// window it opened instead of the configuration.
	if info.Version == "" {
		return nil, fmt.Errorf("Rex's Amber library did not report its configuration; %s", mismatch)
	}
	return &info, nil
}
