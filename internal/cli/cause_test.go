package cli

import (
	"go/ast"
	"go/build"
	"go/importer"
	"go/parser"
	"go/token"
	"go/types"
	"io"
	"io/fs"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
)

// dropsCause is every failure built under `if err != nil` that deliberately
// leaves err out, keyed file, function and the message's format literal.
var dropsCause = map[string]bool{
	// The command it ran printed its own error on the terminal already.
	`internal/buildpush/buildpush.go build "docker compose -p %s -f %s build failed (see the error above)"`:                         true,
	`internal/buildpush/ship.go stream "docker save %s failed (see docker's error above) — the server was sent no complete stream"`: true,
	`internal/buildpush/buildpush.go build "could not tag %s as %s (see docker's error above)"`:                                     true,
	`internal/deploy/tagged.go refType "could not read %s at %s (see git's error above)"`:                                           true,
	`internal/deploy/tagged.go showBlob "could not read %s out of %s (see git's error above)"`:                                      true,
	`internal/deploy/tagged.go checkExtraction "could not list %s at %s (see git's error above)"`:                                   true,
	`internal/release/release.go Resolve "could not list the tags on HEAD (see git's error above)"`:                                 true,
	`internal/ssh/ssh.go Connect "cannot reach %s over ssh (see ssh's own error above)"`:                                            true,
	// The value or the answer is malformed, and the message says how; the
	// parser's own wording would only repeat it.
	`internal/backup/backup.go CheckJitter "%s: --backup-jitter=%s is a day or more — the slot is a time of day, so anything from 86400 wraps"`:                                                                          true,
	`internal/backup/backup.go CheckKeep "%s: %s%s is not a whole number of snapshots to keep"`:                                                                                                                          true,
	`internal/backup/backup.go CheckTimeout "%s: --backup-timeout=%s is too large a number of seconds to hold"`:                                                                                                          true,
	`internal/backup/backup.go CheckHookTimeout "%s: --backup-hook-timeout=%s is outside 30 to 86400 seconds — the nightly job's whole run, every project's backup hook in it, has to fit inside a day"`:                 true,
	`internal/check/server.go DecodeServer "the check probe on %s answered with %d bytes that are not a whole report — truncated, or not this kasbah's"`:                                                                 true,
	`internal/deploy/plan.go Seconds "kasbah.yml: health.timeout '%s' is not a duration kasbah can use — write it as 120s, 5m or 2h"`:                                                                                    true,
	`internal/install/install.go Dist "%s carries no build stamp (it reports '%s'), so it names no version directory — nothing was installed"`:                                                                           true,
	`internal/install/install.go Place "'%s' does not name a version — nothing was installed"`:                                                                                                                           true,
	`internal/mail/cmd.go Decode "the mail read on %s returned a %s that does not decode"`:                                                                                                                               true,
	"internal/marker/marker.go Validate \"%s on %s is not a JSON object — re-run `%s`\"":                                                                                                                                 true,
	`internal/marker/marker.go Compat "%s on %s is not a JSON object"`:                                                                                                                                                   true,
	`internal/migrate/project.go RunProject "%s: schema '%s' is not a number this kasbah can migrate from"`:                                                                                                              true,
	`internal/remote/remote.go Decide "this kasbah's build stamp is '%s', which is not a version — it cannot be ordered against the server's binary"`:                                                                    true,
	`internal/remote/remote.go Decide "the kasbah on the server reports build '%s', which is not a version — this kasbah (%s) will not replace what it cannot order"`:                                                    true,
	`internal/selfupdate/selfupdate.go Releases "%s answered with something that is not a list of releases — nothing was installed"`:                                                                                     true,
	`internal/serverbin/install.go InstallSelf "this kasbah's build '%s' is not a version; it does not install itself"`:                                                                                                  true,
	`internal/serverbin/install.go InstallSelf "%s reports build '%s', which is not a version"`:                                                                                                                          true,
	`internal/serverbin/serverbin.go ship "%s is build %s, and this kasbah is %s — refusing to ship a server binary from another build"`:                                                                                 true,
	`internal/serverbin/serverbin.go ship "install-self on %s answered %q"`:                                                                                                                                              true,
	`internal/serverinit/backup.go ProbeVerdict "the backup credential probe on %s reported counts kasbah cannot read"`:                                                                                                  true,
	`internal/serverinit/mail.go MailCurrent "the mail stack read on %s returned a %s that does not decode"`:                                                                                                             true,
	`internal/serverinit/run.go Run "the read of %s on %s returned a marker that does not decode"`:                                                                                                                       true,
	`internal/serverinit/run.go Run "the read of %s/traefik/%s on %s returned content that does not decode"`:                                                                                                             true,
	`internal/status/status.go Decode "the status probe on %s answered with %d bytes that are not a whole report — truncated, or not this kasbah's (not shown: they carry acme.json, which holds private key material)"`: true,
	`internal/status/status.go JudgeMarker "%s on %s is not a JSON object — look at it before running anything else against this server"`:                                                                                true,
	`internal/status/status.go readMarker "the status probe on %s sent %s back as something that is not base64"`:                                                                                                         true,
	`internal/vlog/record.go ReadProbe "the deploy record read on %s sent %s back as something that is not base64"`:                                                                                                      true,
	// Absent, or not what it must be: the message says so and what to do.
	`cmd/kasbah/install.go installFrom "%s is missing — DIR is a dist/ holding kasbah and server/kasbah-linux-{amd64,arm64}"`:                            true,
	`internal/backup/prune.go Prune "docker is required: kasbah installs no packages, so restic runs as a container here exactly as it does on the VPS"`: true,
	`internal/buildpush/buildpush.go Run "docker is required (install docker and retry)"`:                                                                true,
	`internal/buildpush/compose.go ReadCompose "%s: not found (cwd=%s) — %s"`:                                                                            true,
	`internal/deploy/tagged.go RunTagged "git is required — every file a %s of a tagged version ships comes out of the tag"`:                             true,
	`internal/env/cmd.go Run "no .env.prod.example in %s — that file is the template this renders .env from"`:                                            true,
	`internal/install/install.go Dist "%s is missing — build it: docker compose run --rm build"`:                                                         true,
	`internal/install/install.go CheckLib "%s is not a directory — set KASBAH_LIB_DIR to an empty or previously installed path"`:                         true,
	`internal/manifest/manifest.go Require "No %s in current directory."`:                                                                                true,
	`internal/release/release.go Repo "git is required — kasbah resolves the version from HEAD's tag"`:                                                   true,
	`internal/ssh/ssh.go tmpBase "TMPDIR is '%s', which is not a directory — the ssh control socket has nowhere to live"`:                                true,
	// A template the build embeds: a missing one is a broken build, nothing more.
	`internal/mail/dkim.go RenderDKIM "internal: this kasbah build carries no mail/rspamd-dkim-signing.conf template"`: true,
	`internal/mail/mail.go RenderRegistry "internal: this kasbah build carries no mail/kasbah.yml template"`:           true,
	`internal/serverinit/backup.go BackupRender "internal: this kasbah build carries no backup/%s template"`:           true,
	`internal/serverinit/mail.go MailRender "internal: this kasbah build carries no mail/%s template"`:                 true,
	`internal/serverinit/traefik.go Render "internal: this kasbah build carries no traefik/%s template"`:               true,
	// Malformed input from kasbah's own other end: an internal fault, and the
	// decoder's error adds nothing the message lacks (a password stays unquoted).
	`internal/backup/prune.go stage "internal: %s listed the '%s' repository and sent no password for it"`: true,
	`internal/serverinit/probe.go Limits "internal: nproc '%s' or MemTotal '%s' is out of range"`:          true,
	// git's stderr follows as continuation lines; a mail read that is not JSON
	// was cut short or refused, as the message says.
	`internal/mail/cmd.go Read "the mail read on %s reported nothing kasbah can use — the step was truncated, or the server's kasbah rejected it"`: true,
	`internal/release/dirty.go gitIn "git %s failed in %s"`: true,
}

// A failure built where an error was just caught keeps it: under
// `if X != nil` or `case X != nil:`, X of type error, a cli.Fail or cli.Failf
// chain calls .Cause on X or puts X in its message, unless an inner condition
// already classified X (the message is then the cause), or the site is in
// dropsCause. Two identical literals in one function share a key: same
// message, same reason.
func TestFailureKeepsCause(t *testing.T) {
	fset := token.NewFileSet()
	// Imports read from the export data `go list -export` leaves in the cache.
	out, err := exec.Command("go", "list", "-export", "-deps", "-f", "{{.ImportPath}}\t{{.Export}}", "../../...").Output()
	if err != nil {
		t.Fatal(err)
	}
	exports := map[string]string{}
	for _, l := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		path, file, _ := strings.Cut(l, "\t")
		exports[path] = file
	}
	imp := importer.ForCompiler(fset, "gc", func(path string) (io.ReadCloser, error) { return os.Open(exports[path]) })
	seen := map[string]bool{}
	for _, dir := range []string{"../../cmd", "../../internal", "../../tools"} {
		err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
			if err != nil || !d.IsDir() {
				return err
			}
			pkg, err := parseDir(fset, path)
			if err != nil || len(pkg) == 0 {
				return err
			}
			info := &types.Info{Defs: map[*ast.Ident]types.Object{}, Uses: map[*ast.Ident]types.Object{}}
			conf := types.Config{Importer: imp}
			if _, err := conf.Check(path, fset, slices.Collect(maps.Values(pkg)), info); err != nil {
				return err
			}
			sc := scan{info: info}
			for _, name := range slices.Sorted(maps.Keys(pkg)) {
				rel := strings.TrimPrefix(filepath.ToSlash(name), "../../")
				for _, decl := range pkg[name].Decls {
					fn, ok := decl.(*ast.FuncDecl)
					if !ok || fn.Body == nil {
						continue
					}
					for _, site := range sc.causeDrops(fn.Body) {
						key := rel + " " + fn.Name.Name + " " + site
						seen[key] = true
						if _, ok := dropsCause[key]; !ok {
							t.Errorf("%s: a failure under `if err != nil` drops err: .Cause(err), or add it to dropsCause", key)
						}
					}
				}
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	for key := range dropsCause {
		if !seen[key] {
			t.Errorf("dropsCause names %s, which no longer drops its cause", key)
		}
	}
}

// parseDir is the non-test Go files in dir this platform builds, by path.
func parseDir(fset *token.FileSet, dir string) (map[string]*ast.File, error) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	files := map[string]*ast.File{}
	for _, e := range ents {
		n := e.Name()
		if e.IsDir() || !strings.HasSuffix(n, ".go") || strings.HasSuffix(n, "_test.go") {
			continue
		}
		if ok, err := build.Default.MatchFile(dir, n); err != nil || !ok {
			continue
		}
		path := filepath.Join(dir, n)
		f, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			return nil, err
		}
		files[path] = f
	}
	return files, nil
}

var errorType = types.Universe.Lookup("error").Type().Underlying().(*types.Interface)

type scan struct{ info *types.Info }

// isErr is whether id is a variable of a type that implements error.
func (sc scan) isErr(id *ast.Ident) bool {
	v, ok := sc.info.ObjectOf(id).(*types.Var)
	return ok && types.Implements(v.Type(), errorType)
}

// guard is the conditions and body of an if or a switch case.
func guard(n ast.Node) (conds []ast.Expr, body ast.Node) {
	switch g := n.(type) {
	case *ast.IfStmt:
		return []ast.Expr{g.Cond}, g.Body
	case *ast.CaseClause:
		if len(g.Body) > 0 {
			return g.List, span{g.Colon + 1, g.End()}
		}
	}
	return nil, nil
}

type span struct{ pos, end token.Pos }

func (s span) Pos() token.Pos { return s.pos }
func (s span) End() token.Pos { return s.end }

// causeDrops is the format literal of each failure in body that an
// `X != nil` guard caught and then dropped.
func (sc scan) causeDrops(body *ast.BlockStmt) []string {
	var drops []string
	parent := map[ast.Node]ast.Node{}
	var stack []ast.Node
	ast.Inspect(body, func(n ast.Node) bool {
		if n == nil {
			stack = stack[:len(stack)-1]
			return true
		}
		if len(stack) > 0 {
			parent[n] = stack[len(stack)-1]
		}
		stack = append(stack, n)
		return true
	})
	ast.Inspect(body, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok || !isFail(call) {
			return true
		}
		// The whole chain: Fail(…).Cont(…).Cause(…)….
		var chain ast.Node = call
		for {
			sel, ok := parent[chain].(*ast.SelectorExpr)
			if !ok {
				break
			}
			c, ok := parent[sel].(*ast.CallExpr)
			if !ok || c.Fun != sel {
				break
			}
			chain = c
		}
		for p := parent[call]; p != nil; p = parent[p] {
			conds, gbody := guard(p)
			if gbody == nil || !within(gbody, call) {
				continue
			}
			names := sc.checked(conds)
			if len(names) == 0 {
				// An inner condition that reads a caught error classified it.
				if names = sc.refs(nodes(conds)...); len(names) > 0 && sc.enclosingCatch(parent, p, names) {
					break
				}
				continue
			}
			if !slices.ContainsFunc(names, func(name string) bool { return slices.Contains(sc.refs(chain), name) }) {
				drops = append(drops, format(call))
			}
			break
		}
		return true
	})
	return drops
}

// enclosingCatch is whether an `X != nil` guard around n caught one of names.
func (sc scan) enclosingCatch(parent map[ast.Node]ast.Node, n ast.Node, names []string) bool {
	for p := parent[n]; p != nil; p = parent[p] {
		if conds, body := guard(p); body != nil && within(body, n) {
			if slices.ContainsFunc(sc.checked(conds), func(s string) bool { return slices.Contains(names, s) }) {
				return true
			}
		}
	}
	return false
}

func nodes(es []ast.Expr) []ast.Node {
	ns := make([]ast.Node, len(es))
	for i, e := range es {
		ns[i] = e
	}
	return ns
}

func within(outer, n ast.Node) bool { return n.Pos() >= outer.Pos() && n.End() <= outer.End() }

func isFail(call *ast.CallExpr) bool {
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok {
		return false
	}
	pkg, ok := sel.X.(*ast.Ident)
	return ok && pkg.Name == "cli" && (sel.Sel.Name == "Fail" || sel.Sel.Name == "Failf")
}

// checked is the error identifiers conds test with `X != nil`.
func (sc scan) checked(conds []ast.Expr) []string {
	var names []string
	for _, cond := range conds {
		ast.Inspect(cond, func(n ast.Node) bool {
			b, ok := n.(*ast.BinaryExpr)
			if !ok || b.Op != token.NEQ {
				return true
			}
			id, ok := b.X.(*ast.Ident)
			if nilY, _ := b.Y.(*ast.Ident); ok && nilY != nil && nilY.Name == "nil" && sc.isErr(id) {
				names = append(names, id.Name)
			}
			return true
		})
	}
	return names
}

// refs is the error identifiers ns mention.
func (sc scan) refs(ns ...ast.Node) []string {
	var names []string
	for _, n := range ns {
		ast.Inspect(n, func(n ast.Node) bool {
			if id, ok := n.(*ast.Ident); ok && sc.isErr(id) {
				names = append(names, id.Name)
			}
			return true
		})
	}
	return names
}

func format(call *ast.CallExpr) string {
	i := 0
	if call.Fun.(*ast.SelectorExpr).Sel.Name == "Failf" {
		i = 1
	}
	if i < len(call.Args) {
		if lit, ok := call.Args[i].(*ast.BasicLit); ok {
			return lit.Value
		}
	}
	return strconv.Quote("<not a literal>")
}

// The scan follows the type, not the name, and reads switch cases.
func TestCauseScan(t *testing.T) {
	src := `package p
type oops struct{}
func (oops) Error() string { return "" }
func f() error { return oops{} }
func g() {
	if e := f(); e != nil { cli.Fail("if") }
	switch err := f(); { case err != nil: cli.Fail("case") }
	var p *int
	if p != nil { cli.Fail("pointer") }
	if e := f(); e != nil { cli.Fail("kept").Cause(e) }
}`
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "p.go", src, 0)
	if err != nil {
		t.Fatal(err)
	}
	info := &types.Info{Defs: map[*ast.Ident]types.Object{}, Uses: map[*ast.Ident]types.Object{}}
	(&types.Config{Error: func(error) {}}).Check("p", fset, []*ast.File{f}, info)
	var got []string
	for _, d := range f.Decls {
		if fn, ok := d.(*ast.FuncDecl); ok && fn.Name.Name == "g" {
			got = scan{info: info}.causeDrops(fn.Body)
		}
	}
	if want := []string{`"if"`, `"case"`}; !slices.Equal(got, want) {
		t.Errorf("drops %q, want %q", got, want)
	}
}
