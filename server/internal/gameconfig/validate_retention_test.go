package gameconfig

import (
	"strings"
	"testing"
)

// Each rule the daily loop is held to, made to fire: a validator that cannot
// be made to fire reads as cover.
func TestTheDailyLoopIsHeldToItsRules(t *testing.T) {
	cases := []struct {
		name  string
		spoil func(b *Bundle)
		want  string
	}{
		{"a flask money may carry", func(b *Bundle) {
			for i := range b.Rewards.Tokens {
				if b.Rewards.Tokens[i].ID == "flask_small" {
					b.Rewards.Tokens[i].PaidOK = true
				}
			}
		}, "bought energy is the day's refills"},
		{"published odds that are not the whole", func(b *Bundle) {
			b.Retention.Cart.Odds[0].BP--
		}, "not 10000"},
		{"a purse square that pays diamonds", func(b *Bundle) {
			b.Retention.Calendar.Squares[1].Grant.Diamonds = 5
		}, "a purse square gives gold wages only"},
		{"a crown on the wrong day", func(b *Bundle) {
			b.Retention.Calendar.Squares[5].Crown = true
		}, "the crowns are days 7, 14, 21 and 28"},
		{"a chest past what a board can earn", func(b *Bundle) {
			b.Retention.Weekly.Chests[2].At = 1000
		}, "past the"},
		{"a weekly task counting nothing", func(b *Bundle) {
			b.Retention.Weekly.Pool[0].Deed = "dragons_slain"
		}, "which nothing counts"},
		{"a guide step pointing at nothing", func(b *Bundle) {
			b.Retention.Guide.Steps[1].Target = "somewhere.else"
		}, "the client has no target"},
		{"a road milestone past the cap", func(b *Bundle) {
			b.Retention.Road.Milestones[14].Level = 99
		}, "milestones rise"},
		{"a missing retention section", func(b *Bundle) {
			b.Retention = RetentionConfig{}
		}, "retention section is missing"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			b, err := LoadSeed()
			if err != nil {
				t.Fatal(err)
			}
			c.spoil(b)
			err = b.Validate()
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("Validate said %v; want a refusal saying %q", err, c.want)
			}
		})
	}
}
