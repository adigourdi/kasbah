package probe

import (
	"go/ast"
	"go/parser"
	"go/token"
	"strconv"
	"testing"
)

// The server-side reads write nothing: no filesystem call that creates,
// changes or removes, and of docker only inspect, version, ps and
// `compose version`; df is the one other command.
func TestReadsWriteNothing(t *testing.T) {
	writes := map[string]bool{"WriteFile": true, "Create": true, "OpenFile": true, "Mkdir": true, "MkdirAll": true,
		"Remove": true, "RemoveAll": true, "Rename": true, "Chmod": true, "Chown": true, "Lchown": true, "Chtimes": true,
		"Symlink": true, "Link": true, "Truncate": true, "CreateTemp": true, "MkdirTemp": true}
	verbs := map[string]bool{"inspect": true, "version": true, "ps": true, "compose": true}
	lit := func(e ast.Expr) (string, bool) {
		if c, ok := e.(*ast.CallExpr); ok {
			if id, ok := c.Fun.(*ast.Ident); ok && id.Name == "append" {
				if cl, ok := c.Args[0].(*ast.CompositeLit); ok && len(cl.Elts) > 0 {
					e = cl.Elts[0]
				}
			}
		}
		b, ok := e.(*ast.BasicLit)
		if !ok || b.Kind != token.STRING {
			return "", false
		}
		s, _ := strconv.Unquote(b.Value)
		return s, true
	}
	dockerCalls := 0
	for _, f := range []string{"probe.go", "../status/remote.go", "../backuprec/backuprec.go", "../check/server.go"} {
		file, err := parser.ParseFile(token.NewFileSet(), f, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		ast.Inspect(file, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			name := ""
			switch fn := call.Fun.(type) {
			case *ast.SelectorExpr:
				if x, ok := fn.X.(*ast.Ident); ok {
					name = x.Name + "." + fn.Sel.Name
					if x.Name == "os" && writes[fn.Sel.Name] {
						t.Errorf("%s writes: %s", f, name)
					}
				}
			case *ast.Ident:
				name = fn.Name
			}
			switch name {
			case "probe.Docker", "probe.DockerErr", "probe.DockerAll":
				dockerCalls++
				v, ok := lit(call.Args[0])
				if !ok || !verbs[v] {
					t.Errorf("%s: docker %q is not a read", f, v)
				}
				if v == "compose" {
					if w, _ := lit(call.Args[1]); w != "version" {
						t.Errorf("%s: docker compose %q is not a read", f, w)
					}
				}
			case "exec.Command":
				if v, ok := lit(call.Args[0]); !ok || (v != "docker" && v != "df") {
					t.Errorf("%s runs %q", f, v)
				}
			}
			return true
		})
	}
	if dockerCalls < 8 {
		t.Errorf("found %d docker calls — the scan is not seeing them", dockerCalls)
	}
}
