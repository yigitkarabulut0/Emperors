package gameconfig

import (
	"os"
	"testing"
)

// A stricter validator must never reach a server whose LIVE document it would
// refuse to start on. Point this at a document pulled from the database and it
// says so before the deploy does:
//
//	psql "$DATABASE_URL" -t -A -c "select v.doc from admin.balance_activations a \
//	  join admin.balance_versions v on v.id = a.version_id \
//	  order by a.activated_at desc, a.id desc limit 1" > /tmp/live.json
//	EMPERORS_LIVE_DOC=/tmp/live.json go test -run TestTheLiveDocument ./internal/gameconfig/
//
// Without the variable it skips: the seed is what CI has.
func TestTheLiveDocumentStillPasses(t *testing.T) {
	path := os.Getenv("EMPERORS_LIVE_DOC")
	if path == "" {
		t.Skip("set EMPERORS_LIVE_DOC to a published document to check it")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	doc, err := ParseDoc(raw)
	if err != nil {
		t.Fatalf("the live document does not parse: %v", err)
	}
	b, err := FromDoc(1, doc)
	if err != nil {
		t.Fatalf("the live document does not build: %v", err)
	}
	if err := b.Validate(); err != nil {
		t.Fatalf("this validator would REFUSE the live document, and the server would not start:\n%v", err)
	}
	t.Logf("the live document passes every check this validator makes")
}
