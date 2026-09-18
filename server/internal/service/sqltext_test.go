package service

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// queryStatement returns one named query's SQL, from its "-- name:" line to the
// first semicolon after it.
//
// Several rules live in the SQL itself -- a guard in a WHERE, a column a query
// must write -- and no test in this package has a database, so the statement is
// what gets held.
func queryStatement(t *testing.T, file, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", "db", "queries", file))
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, "-- name: "+name+" ")
	if i < 0 {
		t.Fatalf("%s is gone from db/queries/%s", name, file)
	}
	stmt := src[i:]
	if j := strings.Index(stmt, ";"); j >= 0 {
		stmt = stmt[:j]
	}
	return stmt
}

// serviceSource returns one of this package's own files, for the rules that are
// about where a call is made rather than what it computes.
func serviceSource(t *testing.T, file string) string {
	t.Helper()
	b, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}
