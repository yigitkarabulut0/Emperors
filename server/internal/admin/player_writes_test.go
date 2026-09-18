package admin

import (
	"errors"
	"testing"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

// A panel removal past zero is refused with a reason, before the database.
//
// The currency route used to skip the diamond check entirely, so taking 50
// diamonds from a player holding 20 reached the CHECK constraint and came back
// as a 500.
func TestAdjustRefusesWhatCannotBeRepresented(t *testing.T) {
	p := sqlcdb.AppPlayer{Gold: 1000, Diamonds: 20}

	cases := []struct {
		name               string
		gold, diamonds, xp int64
		points             int32
		want               error
	}{
		{"nothing at all", 0, 0, 0, 0, ErrNothingToDo},
		{"gold past zero", -1001, 0, 0, 0, ErrOutOfRange},
		{"diamonds past zero", 0, -21, 0, 0, ErrOutOfRange},
		{"all the diamonds", 0, -20, 0, 0, nil},
		{"all the gold", -1000, 0, 0, 0, nil},
		{"a grant", 500, 100, 0, 0, nil},
		{"xp only", 0, 0, 250, 0, nil},
		{"points only", 0, 0, 0, 3, nil},
	}
	for _, c := range cases {
		err := validateAdjust(p, c.gold, c.diamonds, c.xp, c.points)
		if c.want == nil && err != nil {
			t.Errorf("%s: refused: %v", c.name, err)
		}
		if c.want != nil && !errors.Is(err, c.want) {
			t.Errorf("%s: got %v, want %v", c.name, err, c.want)
		}
	}
}

// A player who owes diamonds for a refund holds none, so nothing can be removed,
// but a grant is always accepted -- it repays the debt first, in SQL.
func TestAdjustOnAPlayerInDebt(t *testing.T) {
	p := sqlcdb.AppPlayer{Diamonds: 0, DiamondDebt: 240}
	if err := validateAdjust(p, 0, -1, 0, 0); !errors.Is(err, ErrOutOfRange) {
		t.Fatalf("removing a diamond from a player in debt: %v, want out of range", err)
	}
	if err := validateAdjust(p, 0, 100, 0, 0); err != nil {
		t.Fatalf("granting to a player in debt was refused: %v", err)
	}
}
