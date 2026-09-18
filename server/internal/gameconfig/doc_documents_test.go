package gameconfig

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// The published document must carry EVERY document the seed loads.
//
// social.json was added to the seed, to the bundle and to the validator, and
// not to Doc -- so the balance published to the live server had no social block
// at all, every number in it read as zero, and the publish was refused by the
// validator it had already passed locally. That refusal is the lucky case: a
// document whose absence validated would have gone live as zeros.
//
// This holds the two structs to each other by their JSON names, which is what
// the published bytes are keyed by.
func TestThePublishedDocumentCarriesEveryDocument(t *testing.T) {
	names := func(v any) map[string]string {
		out := map[string]string{}
		rt := reflect.TypeOf(v)
		for i := range rt.NumField() {
			f := rt.Field(i)
			tag := f.Tag.Get("json")
			if tag == "" || tag == "-" {
				continue
			}
			for j, c := range tag {
				if c == ',' {
					tag = tag[:j]
					break
				}
			}
			out[tag] = f.Type.String()
		}
		return out
	}
	doc := names(Doc{})
	for tag, typ := range names(Bundle{}) {
		// The bundle carries more than the document: its version, its derived
		// lookups and its indexes. Only the CONFIGS are documents.
		if !strings.HasSuffix(typ, "Config") {
			continue
		}
		got, ok := doc[tag]
		if !ok {
			t.Errorf("the bundle loads %q (%s) and the published document has no such field: "+
				"a publish would drop it and every number in it would read as zero", tag, typ)
			continue
		}
		if got != typ {
			t.Errorf("%q is %s in the bundle and %s in the document", tag, typ, got)
		}
	}

	// And a round trip keeps them: seed -> doc -> bytes -> doc -> bundle.
	seed, err := LoadSeed()
	if err != nil {
		t.Fatalf("load the seed: %v", err)
	}
	raw, err := MarshalDoc(seed.Doc())
	if err != nil {
		t.Fatalf("serialise: %v", err)
	}
	var back Doc
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatalf("read back: %v", err)
	}
	b, err := FromDoc(0, back)
	if err != nil {
		t.Fatalf("a document made from the seed does not load: %v", err)
	}
	if b.Social.Chat.MaxChars != seed.Social.Chat.MaxChars || b.Social.Spy.PerDay != seed.Social.Spy.PerDay {
		t.Errorf("the hall's own numbers did not survive the round trip: %d/%d want %d/%d",
			b.Social.Chat.MaxChars, b.Social.Spy.PerDay, seed.Social.Chat.MaxChars, seed.Social.Spy.PerDay)
	}
}
