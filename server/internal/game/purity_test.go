package game_test

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestGameIsPure enforces the rule the whole design rests on: internal/game
// depends on nothing but the standard library and the config bundle.
//
// The moment a database handle, an HTTP request or time.Now() gets in here, the
// economy stops being unit-testable without infrastructure, the admin panel's
// balance simulator can no longer run the real production code, and rolls stop
// being reproducible for audit. This test is cheap; re-earning those properties
// later would not be.
func TestGameIsPure(t *testing.T) {
	out, err := exec.Command("go", "list", "-deps", "./...").Output()
	if err != nil {
		t.Fatalf("go list: %v", err)
	}

	// Exact stdlib package paths, so a transitive match reports the real
	// offender rather than an incidental substring hit.
	bannedExact := map[string]bool{
		"net/http":     true,
		"database/sql": true,
		"os/exec":      true,
	}
	// Substrings, for module paths where any version or subpackage is banned.
	bannedPrefix := []string{
		"/internal/db", "/internal/httpx", "/internal/service", "/internal/auth",
		"github.com/jackc/pgx", "github.com/go-chi/chi",
	}

	for _, dep := range strings.Fields(string(out)) {
		if bannedExact[dep] {
			t.Errorf("internal/game must stay pure but depends on %q", dep)
			continue
		}
		for _, b := range bannedPrefix {
			if strings.Contains(dep, b) {
				t.Errorf("internal/game must stay pure but depends on %q", dep)
				break
			}
		}
	}
}

// TestGameDoesNotReadTheClock guards the other half of purity: time must always
// arrive as a parameter. A time.Now() inside the economy would make results
// depend on when a test runs and would break the deterministic replay that PvP
// battle verification needs.
//
// This walks the AST rather than grepping, so a comment that merely mentions
// time.Now() (like the package doc, which explains this very rule) does not
// trip it.
func TestGameDoesNotReadTheClock(t *testing.T) {
	err := filepath.Walk(".", func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}

		fset := token.NewFileSet()
		file, err := parser.ParseFile(fset, path, nil, 0) // 0 = drop comments
		if err != nil {
			return err
		}

		ast.Inspect(file, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			sel, ok := call.Fun.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			pkg, ok := sel.X.(*ast.Ident)
			if !ok {
				return true
			}
			if pkg.Name == "time" && (sel.Sel.Name == "Now" || sel.Sel.Name == "Since") {
				t.Errorf("internal/game must take time as a parameter, but %s calls time.%s",
					fset.Position(call.Pos()), sel.Sel.Name)
			}
			return true
		})
		return nil
	})
	if err != nil {
		t.Fatalf("walk: %v", err)
	}
}
