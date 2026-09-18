package gameconfig

import "testing"

// The seed's own social document must load: the hall, the friends, the
// spyglass, the aid and the shared goal, with every gate they name opened by
// progression.sections.
func TestTheSeedHall(t *testing.T) {
	b, err := LoadSeed()
	if err != nil {
		t.Fatal(err)
	}
	s := b.Social
	if s.Chat.MaxChars == 0 || len(s.Chat.Rules) < 3 || s.Chat.SupportEmail == "" {
		t.Fatalf("the hall has no rules to agree to: %+v", s.Chat)
	}
	if b.SectionLevel(s.Friends.Section) == 0 {
		t.Fatalf("social.friends names the gate %q, which opens at no level", s.Friends.Section)
	}
	// The gift is a flask, and a flask is a share of the taker's own pool.
	tok := b.Token(s.Friends.GiftToken)
	if tok == nil || tok.EnergyPct <= 0 || tok.PaidOK {
		t.Errorf("the friends' gift is %q, which is not a free flask: %+v", s.Friends.GiftToken, tok)
	}
	if got := s.Spy.Cost(30); got != s.Spy.GoldPerLevel*30 {
		t.Errorf("scouting a lord of 30 costs %d", got)
	}
	if s.Goal.Kind("energy") == nil {
		t.Error("the shared goal cannot be a day of energy")
	}
	if s.Goal.Kind("no_such_goal") != nil {
		t.Error("an unknown goal kind resolved")
	}
	if last := s.Goal.Tiers[len(s.Goal.Tiers)-1]; last.AtBP != 10000 {
		t.Errorf("the last chest stands at %d bp, not at the goal itself", last.AtBP)
	}
}

// Every one of these has a reason to be refused, and each is a change somebody
// could plausibly make in the generator without thinking it through.
func TestTheHallRefusesWhatWouldBreakIt(t *testing.T) {
	for name, break_ := range map[string]func(s *SocialConfig){
		// A fine prices bad words; the punishment is time.
		"a mute of no minutes": func(s *SocialConfig) { s.Chat.MuteMinutes = 0 },
		// At one report, any lord could silence any other.
		"one report hides a line": func(s *SocialConfig) { s.Chat.ReportsToHide = 1 },
		// App Review 1.2 wants the rules and an address where the talking is.
		"no rules":   func(s *SocialConfig) { s.Chat.Rules = nil },
		"no support": func(s *SocialConfig) { s.Chat.SupportEmail = "write to us" },
		// Two leashes, one of which would never bite.
		"a window that never bites": func(s *SocialConfig) { s.Chat.WindowMax = 10000 },
		// A morning's fresh accounts gifting each other.
		"no account age": func(s *SocialConfig) { s.Friends.MinAccountHours = 0 },
		// A day of play, given away. scripts/pace.py holds the hall to 3%.
		"a day of gifts": func(s *SocialConfig) { s.Friends.GiftsReceivedPerDay = 40 },
		// A gift that is not a flask is a second door for energy.
		"a gift that is not a flask": func(s *SocialConfig) { s.Friends.GiftToken = "pardon" },
		"a gift of nothing":          func(s *SocialConfig) { s.Friends.GiftToken = "" },
		"a gift money could carry":   func(s *SocialConfig) { s.Friends.GiftToken = "energy_potion" },
		// The spyglass is a gold sink; at zero it prices at the floor.
		"a free spyglass": func(s *SocialConfig) { s.Spy.GoldPerLevel = 0 },
		// A stack that alone reaches the timed lane's ceiling.
		"aid that eats the lane": func(s *SocialConfig) { s.Aid.StackBP = 5000 },
		// Answering must be worth something to the one who answers.
		"aid worth nothing": func(s *SocialConfig) { s.Aid.FavourPerAid = 0 },
		// A kingdom carried by one lord and claimed by thirty.
		"no share to claim": func(s *SocialConfig) { s.Goal.MinShareOfEqualBP = 0 },
		// Finishing the goal would pay nothing.
		"a bar that ends early": func(s *SocialConfig) { s.Goal.Tiers[len(s.Goal.Tiers)-1].AtBP = 9000 },
		// A kingdom that levelled its members would make choosing one the game.
		"a goal that pays experience": func(s *SocialConfig) {
			s.Goal.Tiers[0].Grant.XPWages = 40
		},
	} {
		b, err := LoadSeed()
		if err != nil {
			t.Fatal(err)
		}
		break_(&b.Social)
		if p := b.validateSocial(); len(p) == 0 {
			t.Errorf("%s: accepted", name)
		}
	}
}
