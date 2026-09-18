//go:build integration

package itest

import (
	"testing"
	"time"

	"github.com/yigitkarabulut0/emperors/server/internal/iap"
	"github.com/yigitkarabulut0/emperors/server/internal/service"
)

// Another lord's worn frame, title, colour and crest and their Royal Favour
// seal reach every list that shows them, and a patron's frame that lapses with
// no word from Apple comes off at the next sweep.
func TestOtherLordsLookTheSameEverywhere(t *testing.T) {
	s := newStore(t)
	me := s.player(20, 0)
	them := s.player(20, 5_000_000)

	// A patron: the frame and colour are held for the month, and worn.
	sub, _ := s.txn(them, "patronage.month", "", map[string]any{"type": iap.TypeAutoRenewable,
		"expiresDate": s.now.Add(30 * 24 * time.Hour).UnixMilli()})
	if _, err := s.d.VerifyApple(s.ctx, them.ID, sub); err != nil {
		t.Fatal(err)
	}
	if _, err := s.d.WearCosmetic(s.ctx, them.ID, "frame", "frame_patron"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.d.WearCosmetic(s.ctx, them.ID, "crest", "crest_wolf"); err != nil {
		t.Fatal(err)
	}

	// A kingdom of two, founded the way a lord founds one, so its lords list them.
	them = s.reload(them.ID)
	tag := them.ID.String()[:4]
	founded, err := s.d.Found(s.ctx, them.ID, "House "+tag, tag, them.ActionSeq+1)
	if err != nil {
		t.Fatal(err)
	}
	s.exec(`UPDATE app.players SET kingdom_id = (SELECT kingdom_id FROM app.players WHERE id = $1),
		kingdom_role = 'member', kingdom_joined_at = now() WHERE id = $2`, them.ID, me.ID)
	_ = founded
	kv, err := s.d.GetKingdom(s.ctx, me.ID)
	if err != nil {
		t.Fatal(err)
	}
	var member *service.MemberView
	for i := range kv.Members {
		if kv.Members[i].PlayerID == them.ID.String() {
			member = &kv.Members[i]
		}
	}
	if member == nil {
		t.Fatal("the patron is not among the kingdom's lords")
	}
	if member.Worn.Frame == "" || member.Worn.Crest == "" || !member.VIPSeal || member.Avatar == "" {
		t.Fatalf("the kingdom shows the patron as %+v", member)
	}

	// A lord asking to join shows their face and their look to the king.
	asker := s.player(20, 0)
	s.exec(`UPDATE app.players SET vip_points = 5000, cos_color = 'color_patron', avatar = 'queen' WHERE id = $1`, asker.ID)
	if _, err := s.d.SetPolicy(s.ctx, them.ID, "request"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.d.Join(s.ctx, asker.ID, *s.reload(them.ID).KingdomID); err != nil {
		t.Fatal(err)
	}
	kingView, err := s.d.GetKingdom(s.ctx, them.ID)
	if err != nil {
		t.Fatal(err)
	}
	var req *service.JoinRequestView
	for i := range kingView.Requests {
		if kingView.Requests[i].PlayerID == asker.ID.String() {
			req = &kingView.Requests[i]
		}
	}
	if req == nil || req.Avatar != "queen" || req.Worn.Color == "" || !req.VIPSeal {
		t.Fatalf("the king sees the asker as %+v", req)
	}

	// The rankings read the same columns.
	if err := s.d.RefreshLeaderboards(s.ctx); err != nil {
		t.Fatal(err)
	}
	board, err := s.d.GetLeaderboard(s.ctx, me.ID, "wealth")
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, r := range board.Rows {
		if r.Name == them.DisplayName {
			found = r.Worn.Frame == member.Worn.Frame && r.VIPSeal
		}
	}
	if !found {
		t.Fatal("the rankings do not show the patron's frame and seal")
	}

	// The month runs out and Apple says nothing: the sweep takes the frame off.
	s.now = s.now.Add(31 * 24 * time.Hour)
	s.exec(`UPDATE app.player_cosmetics SET expires_at = now() - interval '1 minute'
		WHERE player_id = $1 AND source = 'patronage'`, them.ID)
	jobs := service.ScheduledJobs()
	for _, j := range jobs {
		if j.Name == "cosmetics_lapse" {
			if err := j.Run(s.ctx, s.d, time.Now().UTC()); err != nil {
				t.Fatal(err)
			}
		}
	}
	kv, _ = s.d.GetKingdom(s.ctx, me.ID)
	for _, m := range kv.Members {
		if m.PlayerID == them.ID.String() {
			if m.Worn.Frame != "" {
				t.Fatalf("a lapsed patron frame is still worn: %+v", m.Worn)
			}
			if m.Worn.Crest == "" {
				t.Fatal("the sweep took off a crest the lord still holds")
			}
		}
	}
}
