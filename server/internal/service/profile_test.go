package service

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"

	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// A name that breaks the signup rules is refused before any row is touched.
// Deps here has no pool, so reaching the database would be a nil dereference:
// the test passing is the proof that validation comes first.
func TestRenameRefusesABadNameBeforeTheDatabase(t *testing.T) {
	b, err := gameconfig.LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	d := Deps{Config: b}
	cases := map[string]string{
		"ab":                "too short",
		"1abc":              "starts with a digit",
		"has space":         "has a space",
		"admin":             "is reserved",
		"seventeen_chars_x": "is too long",
	}
	for name, why := range cases {
		_, err := d.Rename(context.Background(), uuid.New(), name, 1)
		if !errors.Is(err, ErrBadName) {
			t.Errorf("%q (%s): got %v, want ErrBadName", name, why, err)
			continue
		}
		if err.Error() == ErrBadName.Error() {
			t.Errorf("%q: the error should carry the rule that was broken, got %q", name, err)
		}
	}
}

// The price a screen quotes and the price the server charges are the same
// field of the same document, and the generator has been run for it.
func TestRenamePriceIsTheStoresAndNeverZero(t *testing.T) {
	b, err := gameconfig.LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	if b.Progression.Store.RenameDiamonds <= 0 {
		t.Fatalf("seed store.rename_diamonds = %d; the generator was not re-run", b.Progression.Store.RenameDiamonds)
	}
}
