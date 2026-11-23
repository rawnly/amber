package engine

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// lockEntry mirrors one entry of amber-lock.json; fields are in the order
// the Lua writer sorts them.
type lockEntry struct {
	Built   string `json:"built,omitempty"`
	Commit  string `json:"commit"`
	Version string `json:"version,omitempty"`
}

type lockData struct {
	Format  int                  `json:"format"`
	Plugins map[string]lockEntry `json:"plugins"`
}

// lockMu serializes this process's lockfile transactions; the mkdir guard
// serializes them with other processes, including the Lua library.
var lockMu sync.Mutex

var lockWait = 10 * time.Second

func readLock(path string) (*lockData, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return &lockData{Format: 1, Plugins: map[string]lockEntry{}}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("cannot read lockfile: %w", err)
	}
	var raw struct {
		Format  any             `json:"format"`
		Plugins json.RawMessage `json:"plugins"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("invalid lockfile: %w", err)
	}
	if f, ok := raw.Format.(float64); !ok || f != 1 || len(raw.Plugins) == 0 {
		return nil, errors.New("invalid or unsupported Amber lockfile")
	}
	lock := &lockData{Format: 1, Plugins: map[string]lockEntry{}}
	// Lua writes an empty table as [], not {}.
	if trimmed := bytes.TrimSpace(raw.Plugins); string(trimmed) == "[]" {
		return lock, nil
	}
	var entries map[string]json.RawMessage
	if err := json.Unmarshal(raw.Plugins, &entries); err != nil {
		return nil, errors.New("invalid or unsupported Amber lockfile")
	}
	for name, rawEntry := range entries {
		var fields map[string]any
		if json.Unmarshal(rawEntry, &fields) != nil {
			return nil, fmt.Errorf("invalid lockfile entry: %s", name)
		}
		var e lockEntry
		commit, ok := fields["commit"].(string)
		if !ok || !validCommit(commit) {
			return nil, fmt.Errorf("invalid lockfile entry: %s", name)
		}
		e.Commit = commit
		if v, present := fields["version"]; present {
			s, ok := v.(string)
			if !ok {
				return nil, fmt.Errorf("invalid lockfile entry: %s", name)
			}
			e.Version = s
		}
		if v, present := fields["built"]; present {
			s, ok := v.(string)
			if !ok || !validCommit(s) {
				return nil, fmt.Errorf("invalid lockfile entry: %s", name)
			}
			e.Built = s
		}
		lock.Plugins[name] = e
	}
	return lock, nil
}

// transaction reads the lockfile under its guard, lets fn change it, and
// writes it back atomically when fn reports a change. Malformed lockfiles are
// never overwritten.
func transaction(path string, fn func(*lockData) (changed bool, err error)) error {
	lockMu.Lock()
	defer lockMu.Unlock()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	guard := path + ".lock"
	deadline := time.Now().Add(lockWait)
	for delay := 25 * time.Millisecond; ; delay = min(delay*2, 500*time.Millisecond) {
		err := os.Mkdir(guard, 0o755)
		if err == nil {
			break
		}
		if !errors.Is(err, os.ErrExist) {
			return err
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("lockfile is busy: %s; if no Amber command is running, remove it (amber clean does)", guard)
		}
		time.Sleep(delay)
	}
	defer os.Remove(guard)

	lock, err := readLock(path)
	if err != nil {
		return err
	}
	changed, err := fn(lock)
	if err != nil || !changed {
		return err
	}
	return writeLock(path, lock)
}

func writeLock(path string, lock *lockData) error {
	// encoding/json sorts map keys, which matches the Lua writer.
	data, err := json.MarshalIndent(lock, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp.*")
	if err != nil {
		return err
	}
	_, werr := tmp.Write(data)
	cerr := tmp.Close()
	if werr != nil || cerr != nil {
		os.Remove(tmp.Name())
		return errors.Join(werr, cerr)
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return nil
}
