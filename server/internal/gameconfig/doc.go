package gameconfig

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
)

// Doc is the whole balance configuration as one publishable document.
//
// The admin panel edits a Doc, the server validates it, and only then does it
// become a version. Keeping it one document rather than seven means a publish is
// atomic: there is never a moment where the job ladder is new and the item
// table is still old.
type Doc struct {
	Jobs        JobsConfig        `json:"jobs"`
	Progression ProgressionConfig `json:"progression"`
	Tiers       TiersConfig       `json:"tiers"`
	Items       ItemsConfig       `json:"items"`
	Soldiers    SoldiersConfig    `json:"soldiers"`
	Estates     EstatesConfig     `json:"estates"`
	Kingdoms    KingdomsConfig    `json:"kingdoms"`
}

// Doc returns this bundle's configuration.
func (b *Bundle) Doc() Doc {
	return Doc{
		Jobs: b.Jobs, Progression: b.Progression, Tiers: b.Tiers,
		Items: b.Items, Soldiers: b.Soldiers, Estates: b.Estates, Kingdoms: b.Kingdoms,
	}
}

// FromDoc builds and validates a bundle from a document.
//
// Validation happens HERE rather than at the call site, so there is no path that
// produces a live bundle without passing it. A config that lets a player earn
// infinite gold must fail to load rather than reach players.
func FromDoc(version int, d Doc) (*Bundle, error) {
	b := &Bundle{
		Version: version,
		Jobs:    d.Jobs, Progression: d.Progression, Tiers: d.Tiers,
		Items: d.Items, Soldiers: d.Soldiers, Estates: d.Estates, Kingdoms: d.Kingdoms,
	}
	if err := b.build(); err != nil {
		return nil, err
	}
	if err := b.Validate(); err != nil {
		return nil, err
	}
	return b, nil
}

// ParseDoc reads a document from its published bytes.
func ParseDoc(raw []byte) (Doc, error) {
	var d Doc
	dec := json.NewDecoder(bytes.NewReader(raw))
	if err := dec.Decode(&d); err != nil {
		return Doc{}, fmt.Errorf("parse balance document: %w", err)
	}
	return d, nil
}

// MarshalDoc serialises a document for publication.
//
// The published BYTES are what gets hashed and stored, so this output is the
// canonical form. Anything that re-serialises a document before hashing would
// break the seal, which is why the version row keeps the text rather than jsonb.
func MarshalDoc(d Doc) ([]byte, error) {
	return json.MarshalIndent(d, "", "  ")
}

// Seal returns the sha256 of exactly these bytes.
func Seal(raw []byte) []byte {
	sum := sha256.Sum256(raw)
	return sum[:]
}
