package service

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// The arena touches no gold, no energy and no shield.
//
// That list IS the feature: it is what makes losing cost nothing but a number,
// which is what makes it safe to fight somebody stronger than you. It is also
// exactly the sort of list that erodes one well-meaning line at a time, so it
// is held by reading the file rather than by hoping.
func TestAnArenaFightTouchesNoGoldNoEnergyNoShield(t *testing.T) {
	src, err := os.ReadFile("arena.go")
	if err != nil {
		t.Fatal(err)
	}
	code := regexp.MustCompile(`(?m)//.*$`).ReplaceAllString(string(src), "")
	for name, why := range map[string]string{
		"ApplyBattleDefender": "a fight in the lists moves no gold",
		"GrantRevenge":        "a fight in the lists is not a grudge",
		"TouchCooldown":       "the lists have their own limit: five a day",
		"settleEnergy":        "a fight in the lists costs no energy",
		"economy.Spend":       "a fight in the lists costs no energy",
		"raidTake":            "a fight in the lists steals nothing",
		"awardReputation":     "the lists must not feed the Throne",
		"ShieldUntil":         "a fight in the lists neither applies nor breaks a shield",
	} {
		if strings.Contains(code, name) {
			t.Errorf("arena.go names %s -- %s", name, why)
		}
	}
}

// Only the fight itself moves the lord's sequence.
//
// A job or an edict that moved action_seq would put the client's queued
// collects out of step by one, and the queue would silently drop them.
func TestOnlyTheFightMovesTheSequence(t *testing.T) {
	for file, allowed := range map[string][]string{
		"arena.go":  {"SpendArenaTicket", "SpendArenaRefresh"},
		"bounty.go": {"PayForBounty"},
		"throne.go": nil,
	} {
		src, err := os.ReadFile(file)
		if err != nil {
			t.Fatalf("%s: %v", file, err)
		}
		code := regexp.MustCompile(`(?m)//.*$`).ReplaceAllString(string(src), "")
		for _, loc := range regexp.MustCompile(`ActionSeq:`).FindAllStringIndex(code, -1) {
			// The statement this sits in must be one of the allowed ones.
			window := code[maxInt(0, loc[0]-200):loc[0]]
			ok := false
			for _, a := range allowed {
				if strings.Contains(window, a) {
					ok = true
				}
			}
			if !ok {
				t.Errorf("%s writes action_seq somewhere it may not: ...%s", file, window[maxInt(0, len(window)-90):])
			}
		}
	}
	// And the refund a job makes must not carry one at all.
	sql, err := os.ReadFile("../../db/queries/pvp.sql")
	if err != nil {
		t.Fatal(err)
	}
	i := strings.Index(string(sql), "-- name: RefundBounty")
	if i < 0 {
		t.Fatal("RefundBounty is gone -- the expiry job would have to use CreditGold, which writes a sequence")
	}
	stmt := string(sql)[i:]
	if j := strings.Index(stmt, ";"); j > 0 {
		stmt = stmt[:j]
	}
	if strings.Contains(stmt, "action_seq") {
		t.Fatal("RefundBounty writes action_seq: a job must never move the number the client's collects count on")
	}
}

// Every letter Rekabet sends is a kind checkDraft allows.
//
// A kind missing from that switch makes a crowning that writes its row, holds
// its regalia and sends NOTHING -- and, worse, whose first failed send rolls
// the whole crowning back.
func TestEveryPvPMailKindIsAllowed(t *testing.T) {
	d := seedDeps(t)
	for _, kind := range []string{MailArena, MailBounty, MailThrone} {
		if err := d.checkDraft(MailDraft{Kind: kind, Title: "x"}); err != nil {
			t.Errorf("a %q letter is refused: %v", kind, err)
		}
	}
}

// The two lists of allowed mail kinds -- the Go switch and the database's
// CHECK -- are the same list in two languages.
func TestTheMailKindsAgreeWithTheDatabase(t *testing.T) {
	src, err := os.ReadFile("mail.go")
	if err != nil {
		t.Fatal(err)
	}
	body := string(src)
	i := strings.Index(body, "func (d Deps) checkDraft(")
	if i < 0 {
		t.Fatal("checkDraft is gone")
	}
	sw := body[i : i+700]
	mig, err := os.ReadFile("../../db/migrations/00044_pvp.sql")
	if err != nil {
		t.Fatal(err)
	}
	up := string(mig)
	if j := strings.Index(up, "-- +goose Down"); j > 0 {
		up = up[:j]
	}
	k := strings.LastIndex(up, "mail_kind_check CHECK (kind IN (")
	if k < 0 {
		t.Fatal("the migration no longer states the mail kinds")
	}
	list := up[k:]
	for _, kind := range regexp.MustCompile(`'([a-z_]+)'`).FindAllStringSubmatch(list[:strings.Index(list, "));")], 1000) {
		name := kind[1]
		if !strings.Contains(sw, `"`+name+`"`) && !strings.Contains(sw, capitalised(name)) {
			t.Errorf("the database allows %q but checkDraft does not", name)
		}
	}
}

// capitalised is the constant a kind is likely to be named by (MailBounty).
func capitalised(s string) string {
	parts := strings.Split(s, "_")
	out := "Mail"
	for _, p := range parts {
		if p == "" {
			continue
		}
		out += strings.ToUpper(p[:1]) + p[1:]
	}
	return out
}

// The dev tools must reset the arena's day, or /dev/advance silently does not.
func TestTheNewDaysAreTimeTravelled(t *testing.T) {
	src, err := os.ReadFile("../../db/queries/dev.sql")
	if err != nil {
		t.Fatal(err)
	}
	body := string(src)
	i := strings.Index(body, "-- name: WarpPlayerClocks")
	if i < 0 {
		t.Fatal("WarpPlayerClocks is gone")
	}
	stmt := body[i:]
	if j := strings.Index(stmt, ";"); j > 0 {
		stmt = stmt[:j]
	}
	for _, col := range []string{"arena_day", "arena_first_win_on", "bounty_day"} {
		if !strings.Contains(stmt, col) {
			t.Errorf("the dev warp does not move %s: /dev/advance would not give the day back", col)
		}
	}
}

// No arena grant may level anybody: the arena is outside pace.py's budget, and
// it stays outside because the balance cannot carry experience into it.
func TestArenaGrantsCarryNoExperienceOrEnergy(t *testing.T) {
	d := seedDeps(t)
	a := d.Config.PvP.Arena
	grants := []struct {
		what string
		g    interface{ Empty() bool }
	}{}
	_ = grants
	all := []struct {
		what string
		xp   int64
		xpw  int64
		toks map[string]int64
	}{
		{"first_win", a.FirstWin.XP, a.FirstWin.XPWages, a.FirstWin.Tokens},
		{"win_grant", a.WinGrant.XP, a.WinGrant.XPWages, a.WinGrant.Tokens},
		{"loss_grant", a.LossGrant.XP, a.LossGrant.XPWages, a.LossGrant.Tokens},
	}
	for i, m := range a.Milestones {
		all = append(all, struct {
			what string
			xp   int64
			xpw  int64
			toks map[string]int64
		}{"milestone " + string(rune('1'+i)), m.Grant.XP, m.Grant.XPWages, m.Grant.Tokens})
	}
	for _, g := range all {
		if g.xp != 0 || g.xpw != 0 {
			t.Errorf("arena.%s carries experience", g.what)
		}
		for id := range g.toks {
			if tok := d.Config.Token(id); tok != nil && tok.EnergyPct > 0 {
				t.Errorf("arena.%s carries %q, which is energy", g.what, id)
			}
		}
	}
}

// The decree rides the TIMED lane. Filed permanently, an hour's edict would
// last for ever and the lane's cap would stop being a cap.
func TestTheDecreeIsFiledOnTheTimedLane(t *testing.T) {
	src, err := os.ReadFile("estates.go")
	if err != nil {
		t.Fatal(err)
	}
	body := string(src)
	i := strings.Index(body, "d.Boosts.Decree()")
	if i < 0 {
		t.Fatal("loadEffects no longer reads the Throne's decree")
	}
	window := body[i : i+320]
	if !strings.Contains(window, "addLiveBonus(") {
		t.Fatal("the decree is not filed through addLiveBonus -- it would miss the timed lane")
	}
}
