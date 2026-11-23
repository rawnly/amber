package engine

import (
	"context"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

var (
	rangePattern = regexp.MustCompile(`^([\^~])(\d+)\.(\d+)\.(\d+)$`)
	tagPattern   = regexp.MustCompile(`^v?(\d+)\.(\d+)\.(\d+)$`)
)

type semver [3]int

func (a semver) less(b semver) bool {
	for i := range a {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return false
}

func parseInts(m []string) semver {
	var v semver
	for i := range v {
		v[i], _ = strconv.Atoi(m[i])
	}
	return v
}

// bestTag picks the highest stable tag that satisfies a ^x.y.z or ~x.y.z
// range, with npm's caret rules for major version zero. ok is false when the
// version is not a range.
func bestTag(version string, tags []string) (tag string, ok bool, err error) {
	m := rangePattern.FindStringSubmatch(version)
	if m == nil {
		return "", false, nil
	}
	op, base := m[1], parseInts(m[2:])
	var best semver
	for _, t := range tags {
		tm := tagPattern.FindStringSubmatch(strings.TrimSpace(t))
		if tm == nil {
			continue
		}
		v := parseInts(tm[1:])
		if v.less(base) {
			continue
		}
		var within bool
		if op == "~" {
			within = v[0] == base[0] && v[1] == base[1]
		} else {
			within = v[0] == base[0] && (base[0] > 0 || (v[1] == base[1] && (base[1] > 0 || v[2] == base[2])))
		}
		if within && (tag == "" || best.less(v)) {
			tag, best = strings.TrimSpace(t), v
		}
	}
	if tag == "" {
		return "", true, fmt.Errorf("no stable tag matches %s", version)
	}
	return tag, true, nil
}

// resolveVersion turns a plugin's version into a ref Git can check out,
// using only what the checkout already has: ranges pick a local tag, a tag
// wins over a remote branch of the same name, and anything else (a commit)
// is used as is.
func resolveVersion(ctx context.Context, dir, version string) (string, error) {
	if rangePattern.MatchString(version) {
		out, err := git(ctx, gitCall{dir: dir}, "tag", "--list")
		if err != nil {
			return "", err
		}
		tag, _, err := bestTag(version, strings.Split(out, "\n"))
		return tag, err
	}
	if ok, _ := gitOK(ctx, dir, "show-ref", "--verify", "--quiet", "refs/tags/"+version); ok {
		return version, nil
	}
	if ok, _ := gitOK(ctx, dir, "show-ref", "--verify", "--quiet", "refs/remotes/origin/"+version); ok {
		return "origin/" + version, nil
	}
	return version, nil
}
