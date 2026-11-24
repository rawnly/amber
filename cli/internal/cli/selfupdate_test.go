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
