package engine

import "golang.org/x/sys/unix"

// renameExclusive moves from to to, failing if to already exists.
func renameExclusive(from, to string) error {
	return unix.RenamexNp(from, to, unix.RENAME_EXCL)
}
