package check

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
)

var ruleID = regexp.MustCompile(`^[A-Z]{1,2}[0-9]{2}$`)

func TestRulesTable(t *testing.T) {
	seen := map[string]bool{}
	area := 0
	for _, r := range Rules {
		if !ruleID.MatchString(r.ID) || seen[r.ID] {
			t.Errorf("%q: malformed or repeated ID", r.ID)
		}
		seen[r.ID] = true
		i := slices.Index(Areas, r.Area)
		if i < area {
			t.Errorf("%s: area %q is not one of Areas, or out of their order", r.ID, r.Area)
		} else {
			area = i
		}
		if !slices.Contains([]string{"fail", "warn", "fail/warn", "retired"}, r.Level) {
			t.Errorf("%s: level %q", r.ID, r.Level)
		}
		if r.Title == "" || r.Why == "" || r.Change == "" || strings.Contains(r.Title+r.Why+r.Change, "\n") {
			t.Errorf("%s: a title, why and change of one line each", r.ID)
		}
	}
	if r, ok := Lookup("hk01"); !ok || r.ID != "HK01" {
		t.Errorf("Lookup is not case-insensitive: %v", r)
	}
	if _, ok := Lookup("C06"); ok {
		t.Error("Lookup found C06, which no rule has")
	}
}

// compliance.md's catalog rows, each with the level and the area heading it
// sits under: the same IDs as Rules, at the same levels, in the same areas.
func TestRulesMatchCompliance(t *testing.T) {
	data, err := os.ReadFile("../../docs/compliance.md")
	if err != nil {
		t.Fatal(err)
	}
	type row struct{ area, level string }
	doc := map[string]row{}
	area := ""
	for _, l := range strings.Split(strings.ReplaceAll(string(data), "\r", ""), "\n") {
		if h, ok := strings.CutPrefix(l, "### "); ok {
			area, _, _ = strings.Cut(h, " ")
			continue
		}
		cells := strings.Split(l, " | ")
		if len(cells) < 3 || !strings.HasPrefix(l, "| ") {
			continue
		}
		id := strings.TrimPrefix(cells[0], "| ")
		if !ruleID.MatchString(id) {
			continue
		}
		level := strings.ReplaceAll(strings.TrimSuffix(strings.TrimSpace(cells[2]), " |"), " / ", "/")
		if level == "—" {
			level = "retired"
		}
		doc[id] = row{area, level}
	}
	for _, r := range Rules {
		d, ok := doc[r.ID]
		switch {
		case !ok:
			t.Errorf("%s is in Rules, not in compliance.md's catalog", r.ID)
		case d.level != r.Level || d.area != r.Area:
			t.Errorf("%s: compliance.md has %s under %s, Rules %s under %s", r.ID, d.level, d.area, r.Level, r.Area)
		}
		delete(doc, r.ID)
	}
	for id := range doc {
		t.Errorf("%s is in compliance.md's catalog, not in Rules", id)
	}
}

// Every verdict line the package can print names rules of the table: each
// passf/warnf/failf/failErr call leads with a literal list of IDs.
func TestEmittedIDsInRules(t *testing.T) {
	files, _ := filepath.Glob("*.go")
	fset := token.NewFileSet()
	calls := 0
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		file, err := parser.ParseFile(fset, f, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, d := range file.Decls {
			fn, ok := d.(*ast.FuncDecl)
			if !ok || slices.Contains([]string{"passf", "warnf", "failf", "failErr"}, fn.Name.Name) {
				continue
			}
			ast.Inspect(fn, func(n ast.Node) bool {
				call, ok := n.(*ast.CallExpr)
				if !ok {
					return true
				}
				sel, ok := call.Fun.(*ast.SelectorExpr)
				if !ok || !slices.Contains([]string{"passf", "warnf", "failf", "failErr"}, sel.Sel.Name) {
					return true
				}
				calls++
				lit, ok := call.Args[0].(*ast.BasicLit)
				if !ok || lit.Kind != token.STRING {
					t.Errorf("%s: %s's IDs are not a string literal", fset.Position(call.Pos()), sel.Sel.Name)
					return true
				}
				ids, _ := strconv.Unquote(lit.Value)
				if ids == "" {
					return true
				}
				for _, id := range strings.Split(ids, ",") {
					if _, ok := Lookup(id); !ok || !ruleID.MatchString(id) {
						t.Errorf("%s: %q is not a rule of the table", fset.Position(call.Pos()), id)
					}
				}
				return true
			})
		}
	}
	if calls < 100 {
		t.Errorf("found %d verdict calls; the scan is not seeing the package", calls)
	}

	// And a run's lines as printed: mark, IDs, text.
	project(t, map[string]string{"kasbah.yml": man + "hooks: {backup: [x]}\nmail: {domain: x.io}\n", ".env.prod.example": "KASBAH_X=1\n"})
	out, _, _ := check(t)
	line := regexp.MustCompile(`^  [✓⚠✗] (\S+) `)
	n := 0
	for _, l := range strings.Split(out, "\n") {
		m := line.FindStringSubmatch(l)
		if m == nil {
			continue
		}
		n++
		for _, id := range strings.Split(m[1], ",") {
			if _, ok := Lookup(id); !ok {
				t.Errorf("line %q names %q, no rule of the table", l, id)
			}
		}
	}
	if n < 20 {
		t.Errorf("only %d verdict lines in:\n%s", n, out)
	}
}
