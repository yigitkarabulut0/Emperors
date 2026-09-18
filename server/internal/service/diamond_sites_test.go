package service

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// diamondWriters is every query allowed to change players.diamonds.
//
// A new one is a conscious act: add it here, and every function that calls it
// must write the diamond ledger (TestEveryDiamondWriteIsLedgered). The ledger is
// what a refund reads and what the reconciliation check proves the balances
// against, so a write that bypasses it is a balance nobody can explain.
var diamondWriters = []string{
	"AdminAdjustPlayer",
	"ApplyBattleAttacker",
	"ApplyCollect",
	"BuyEnergyRefill",
	"BuyShield",
	"CreditDiamonds",
	"PayForReroll",
	"RefundDiamonds",
	"RenamePlayer",
	"SpendDiamonds",
}

// assignsDiamonds matches "diamonds = ..." in a SET list. Not "diamonds >=" in a
// WHERE (the > sits between the word and the =), and not diamond_debt.
var assignsDiamonds = regexp.MustCompile(`(?m)\bdiamonds\s*=[^=]`)

// sqlDiamondWriters reads every named query in db/queries and returns those
// that assign players.diamonds.
func sqlDiamondWriters(t *testing.T) []string {
	t.Helper()
	files, err := filepath.Glob(filepath.Join("..", "..", "db", "queries", "*.sql"))
	if err != nil || len(files) == 0 {
		t.Fatalf("no query files found: %v", err)
	}
	var out []string
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		parts := strings.Split(string(b), "-- name: ")
		for _, part := range parts[1:] {
			name := strings.Fields(part)[0]
			stmt := part
			if j := strings.Index(stmt, ";"); j >= 0 {
				stmt = stmt[:j]
			}
			// Comments above the next query can mention diamonds freely.
			var code []string
			for _, line := range strings.Split(stmt, "\n") {
				if !strings.HasPrefix(strings.TrimSpace(line), "--") {
					code = append(code, line)
				}
			}
			body := strings.Join(code, "\n")
			if strings.Contains(strings.ToUpper(body), "UPDATE APP.PLAYERS") && assignsDiamonds.MatchString(body) {
				out = append(out, name)
			}
		}
	}
	sort.Strings(out)
	return out
}

// The set of queries that write diamonds is exactly the reviewed list.
func TestOnlyReviewedQueriesWriteDiamonds(t *testing.T) {
	got := sqlDiamondWriters(t)
	want := append([]string(nil), diamondWriters...)
	sort.Strings(want)
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("queries that write players.diamonds changed.\n got: %v\nwant: %v\n"+
			"A new writer must be added to diamondWriters and ledgered at every call site.", got, want)
	}
}

// Every function that runs a diamond-writing query also writes the ledger.
func TestEveryDiamondWriteIsLedgered(t *testing.T) {
	writers := map[string]bool{}
	for _, w := range diamondWriters {
		writers[w] = true
	}
	dirs := []string{".", filepath.Join("..", "admin")}
	calls := 0
	for _, dir := range dirs {
		files, err := filepath.Glob(filepath.Join(dir, "*.go"))
		if err != nil {
			t.Fatal(err)
		}
		for _, f := range files {
			if strings.HasSuffix(f, "_test.go") {
				continue
			}
			fset := token.NewFileSet()
			file, err := parser.ParseFile(fset, f, nil, 0)
			if err != nil {
				t.Fatal(err)
			}
			for _, decl := range file.Decls {
				fn, ok := decl.(*ast.FuncDecl)
				if !ok || fn.Body == nil {
					continue
				}
				var wrote []string
				ledgered := false
				ast.Inspect(fn.Body, func(n ast.Node) bool {
					call, ok := n.(*ast.CallExpr)
					if !ok {
						return true
					}
					sel, ok := call.Fun.(*ast.SelectorExpr)
					if !ok {
						return true
					}
					if writers[sel.Sel.Name] {
						wrote = append(wrote, sel.Sel.Name)
					}
					if id, ok := sel.X.(*ast.Ident); ok && id.Name == "ledger" && sel.Sel.Name == "Diamonds" {
						ledgered = true
					}
					return true
				})
				calls += len(wrote)
				if len(wrote) > 0 && !ledgered {
					t.Errorf("%s: %s calls %v and never writes the diamond ledger",
						f, fn.Name.Name, wrote)
				}
			}
		}
	}
	if calls < 10 {
		t.Fatalf("found %d diamond-writing calls; the scan is not seeing the call sites", calls)
	}
}
