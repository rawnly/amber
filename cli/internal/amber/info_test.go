package amber

import (
	"encoding/json"
	"testing"
)

func TestDecodeInfo(t *testing.T) {
	data := `{
		"version": "0.1.0", "dir": "/a", "root": "/r", "lockfile": "/l.json", "state_root": "/s",
		"plugins": [
			{"name": "a/b", "slug": "a/b", "dir": "/r/a/b", "main": "b", "enabled": true, "local_path": false,
			 "build": [{"type": "shell", "command": "make"}, {"type": "lua"}], "load_status": "loaded"},
			{"name": "a/c", "dir": "/c", "main": "c", "enabled": false, "local_path": true, "build": {}}
		]
	}`
	var info Info
	if err := json.Unmarshal([]byte(data), &info); err != nil {
		t.Fatal(err)
	}
	if len(info.Plugins) != 2 || info.Root != "/r" {
		t.Fatalf("%+v", info)
	}
	b, _ := info.Find("a/b")
	if !b.Managed() || !b.HasLuaBuild() || b.Build[0].Command != "make" {
		t.Fatalf("%+v", b)
	}
	c, _ := info.Find("a/c")
	if c.Managed() || len(c.Build) != 0 {
		t.Fatalf("%+v", c)
	}

	var empty Info
	if err := json.Unmarshal([]byte(`{"root": "/r", "plugins": {}}`), &empty); err != nil || len(empty.Plugins) != 0 {
		t.Fatalf("empty plugin table: %+v %v", empty, err)
	}
}
