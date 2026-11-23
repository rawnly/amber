//go:build !darwin && !linux

package engine

func renameExclusive(from, to string) error { return renameChecked(from, to) }
