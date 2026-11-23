package engine

import (
	"errors"

	"golang.org/x/sys/unix"
)

// renameExclusive moves from to to, failing if to already exists. File
// systems without RENAME_NOREPLACE fall back to check-then-rename, which the
// caller's per-plugin guard keeps safe against other Amber processes.
func renameExclusive(from, to string) error {
	err := unix.Renameat2(unix.AT_FDCWD, from, unix.AT_FDCWD, to, unix.RENAME_NOREPLACE)
	if errors.Is(err, unix.EINVAL) || errors.Is(err, unix.ENOSYS) {
		return renameChecked(from, to)
	}
	return err
}
