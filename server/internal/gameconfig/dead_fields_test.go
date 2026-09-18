package gameconfig

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// A BALANCE FIELD THAT NOTHING READS.
//
// This repository has paid for this one twice. `tiers.json`'s `stat_mult`
// drifted to a completely different curve from the multiplier the game runs on,
// and nothing caught it because nothing read it. Then `commerce.json`'s
// `skip_ads` sat on Crown Patronage for days promising a benefit no code gave.
// Both are the same failure: a number in the published document that reads as a
// rule and is not one.
//
// So the dead set is written down here instead of discovered. Add a field that
// nothing outside gameconfig ever names and this test fails, with two honest
// ways out: wire it up, or put it on the list below with the reason it is inert.
// What must not happen is a third one arriving quietly.
//
// Two fields left this list the day it was written: `progression.energy.overflow`
// and a campaign captain's `gear.ilvl`. Neither was wired into the game -- each
// got the check it should have had, which is the better of the two ways out.
var deadOnPurpose = map[string]string{
	"SkipAds": "Crown Patronage's ad-skipping. The game's only advert is opt-in and PAYS " +
		"the watcher (commerce.ads), so honouring it would take the herald's diamonds away " +
		"from the one lord who paid. Kept as the owner's to spend if unsolicited adverts " +
		"ever exist; see the comment at the field.",
}

var jsonField = regexp.MustCompile("^\t([A-Z]\\w*)\\s+[\\[\\]\\*\\w\\.]+\\s+`json:\"([^\",]+)")

func TestNoBalanceFieldGoesUnread(t *testing.T) {
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}

	// Every field the published document can carry.
	type fld struct{ goName, jsonName, file string }
	var fields []fld
	cfg := filepath.Join(root, "internal", "gameconfig")
	entries, err := os.ReadDir(cfg)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".go") || strings.HasSuffix(e.Name(), "_test.go") {
			continue
		}
		body, err := os.ReadFile(filepath.Join(cfg, e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		for _, line := range strings.Split(string(body), "\n") {
			if m := jsonField.FindStringSubmatch(line); m != nil {
				fields = append(fields, fld{m[1], m[2], e.Name()})
			}
		}
	}
	if len(fields) < 100 {
		t.Fatalf("only %d balance fields found: the scan is broken, not the balance", len(fields))
	}

	// Every line of real source that could read one. Tests do not count: a
	// field only a test names is still dead in the game.
	var source []string
	for _, dir := range []string{"internal", "cmd"} {
		err := filepath.Walk(filepath.Join(root, dir), func(path string, info os.FileInfo, err error) error {
			if err != nil || info.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
				return err
			}
			body, rerr := os.ReadFile(path)
			if rerr != nil {
				return rerr
			}
			source = append(source, string(body))
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}

	var dead []fld
	for _, f := range fields {
		if read(source, "."+f.goName) {
			continue
		}
		dead = append(dead, f)
	}

	found := map[string]bool{}
	for _, f := range dead {
		found[f.goName] = true
		if _, ok := deadOnPurpose[f.goName]; !ok {
			t.Errorf("%s (%s, %s) is in the published document and no code outside gameconfig "+
				"ever names it. Wire it up, or add it to deadOnPurpose with the reason it is "+
				"inert -- a number that reads as a rule and is not one is how stat_mult and "+
				"skip_ads both got here", f.jsonName, f.goName, f.file)
		}
	}
	// And the list does not outlive what it describes.
	var stale []string
	for name := range deadOnPurpose {
		if !found[name] {
			stale = append(stale, name)
		}
	}
	sort.Strings(stale)
	for _, name := range stale {
		t.Errorf("deadOnPurpose still lists %s, which something reads now: take it off the list", name)
	}
}

// read reports whether any line of source names `dot` somewhere other than the
// struct declaration that introduced it.
func read(source []string, dot string) bool {
	for _, body := range source {
		if !strings.Contains(body, dot) {
			continue
		}
		for _, line := range strings.Split(body, "\n") {
			if strings.Contains(line, dot) && !strings.Contains(line, "`json:\"") {
				return true
			}
		}
	}
	return false
}
