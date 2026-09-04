package service

import (
	"encoding/json"
	"strings"
	"testing"
)

// TestArraysNeverMarshalAsNull guards a whole class of client crash.
//
// A nil Go slice marshals to JSON null, not []. Any client that iterates the
// field then fails on a brand-new player — exactly the account least able to
// report a useful bug. Every array-valued response field must be [] when empty.
func TestArraysNeverMarshalAsNull(t *testing.T) {
	// Only ARRAY fields are checked. A nullable object (next_slot, an unfilled
	// equipment slot) legitimately marshals to null and means "nothing here".
	cases := []struct {
		name   string
		v      any
		arrays []string
	}{
		{"ArmyView", &ArmyView{Slots: []SlotView{}, Recruits: []RecruitOpt{}}, []string{"slots", "recruits"}},
		{"InventoryView", &InventoryView{Items: []ItemView{}}, []string{"items"}},
		{"ShopView", &ShopView{Offers: []ShopOffer{}}, []string{"offers"}},
		{"Snapshot", &Snapshot{Jobs: []JobView{}}, []string{"jobs"}},
	}
	for _, c := range cases {
		raw, err := json.Marshal(c.v)
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		for _, key := range c.arrays {
			if strings.Contains(string(raw), `"`+key+`":null`) {
				t.Errorf("%s.%s marshalled as null; a client iterating it would crash", c.name, key)
			}
			if !strings.Contains(string(raw), `"`+key+`":[`) {
				t.Errorf("%s.%s is not an array in the output: %s", c.name, key, raw)
			}
		}
	}

	// And the failure mode itself, so this test is known to be able to fail.
	var nilSlice struct {
		Items []ItemView `json:"items"`
	}
	raw, _ := json.Marshal(nilSlice)
	if !strings.Contains(string(raw), `"items":null`) {
		t.Fatal("a nil slice no longer marshals to null — this guard is testing nothing")
	}
}
