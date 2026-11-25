package cli

import "testing"

func TestIsHomebrewPath(t *testing.T) {
	cases := map[string]bool{
		"/opt/homebrew/Cellar/amber-rex/0.1.0/libexec/bin/amber":              true,
		"/home/linuxbrew/.linuxbrew/Cellar/amber-rex/0.1.0/libexec/bin/amber": true,
		"/usr/local/Cellar/amber-rex/0.1.0/libexec/bin/amber":                 true,
		"/Users/me/.local/share/rex/amber/bin/amber":                          false,
		"/opt/homebrew/bin/amber":                                             false,
		"/Users/me/Cellar-notes/amber":                                        false,
	}
	for path, want := range cases {
		if got := isHomebrewPath(path); got != want {
			t.Errorf("%s: got %v, want %v", path, got, want)
		}
	}
}

func TestIsNewer(t *testing.T) {
	cases := []struct {
		latest, current string
		want, err       bool
	}{
		{"v0.2.0", "v0.1.9", true, false},
		{"v0.10.0", "v0.9.0", true, false},
		{"v1.0.0", "v1.0.0", false, false},
		{"v1.0.0", "v1.1.0", false, false}, // never downgrade
		{"v1.0.0", "dev", false, true},
		{"v1.0.0", "v1.0.0-rc1", false, true},
		{"nightly", "v1.0.0", false, true},
	}
	for _, c := range cases {
		got, err := isNewer(c.latest, c.current)
		if got != c.want || (err != nil) != c.err {
			t.Errorf("isNewer(%q, %q) = %v, %v", c.latest, c.current, got, err)
		}
	}
}
