package main

import (
	"bytes"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/help"
)

func TestTopLevel(t *testing.T) {
	tests := []struct {
		args     []string
		code     int
		out, err string
	}{
		{nil, 0, "Usage: kasbah [--version]", ""},
		{[]string{"-h"}, 0, "server upgrade-traefik USER@HOST", ""},
		{[]string{"--help"}, 0, "init-project [--name=<n>]", ""},
		{[]string{"--version"}, 0, "kasbah 1.0.0 (schema 1)\n", ""},
		{[]string{"-v"}, 0, "kasbah 1.0.0 (schema 1)\n", ""},
		{[]string{"version"}, 0, "kasbah 1.0.0 (schema 1)\n", ""},
		{[]string{"version", "--short"}, 1, "", "version: unknown flag '--short'"},
		{[]string{"version", "1.0"}, 1, "", "version: unexpected argument '1.0'"},
		{[]string{"version", "--help"}, 0, "Usage: kasbah version", ""},
		{[]string{"version", "-h"}, 0, "Usage: kasbah version", ""},
		{[]string{"server"}, 1, "", "server: no subcommand given (expected: init, status, prune, backup-prune, destroy, upgrade-traefik, add-mail-domain, mail-dkim, mail-setup-guide)"},
		{[]string{"server", "--help"}, 0, "Usage: kasbah server <subcommand>", ""},
		{[]string{"server", "-h"}, 0, "  init USER@HOST [flags]", ""},
		{[]string{"server", "--help"}, 0, "\n  mail-dkim USER@HOST DOMAIN [--replace-keys|--keep-keys]\n", ""},
		{[]string{"server", "statsu"}, 1, "", "server: unknown subcommand 'statsu'"},
		{[]string{"deplyo"}, 1, "", "unknown command 'deplyo'"},
		{[]string{"help"}, 0, "\nTopics:\n", ""},
		{[]string{"help"}, 0, "kasbah help files ", ""},
		{[]string{"help", "--help"}, 0, "\nTopics:\n", ""},
		{[]string{"help", "rules"}, 0, "\n  T05   fail       No router claims", ""},
		{[]string{"help", "t05"}, 0, "T05  fail  (Traefik)\n", ""},
		{[]string{"help", "files"}, 0, "/blob/v1.0.0/docs/authoring.md\n", ""},
		{[]string{"help", "nope"}, 1, "", "help: unknown topic 'nope' — the topics are files, setups, rules, debug"},
		{[]string{"help", "C06"}, 1, "", "help: unknown topic 'C06'"},
		{[]string{"help", "rules", "x"}, 1, "", "help: unexpected argument 'x' — help takes one topic: files, setups, rules, debug, troubleshooting, a rule ID (C01), or a command"},
	}
	for _, tt := range tests {
		var so, se bytes.Buffer
		code := topLevel(&cli.Output{Stdout: &so, Stderr: &se}, "1.0.0", tt.args)
		if code != tt.code || !strings.Contains(so.String(), tt.out) || !strings.Contains(se.String(), tt.err) {
			t.Errorf("%q: exit %d, stdout %q, stderr %q", tt.args, code, so.String(), se.String())
		}
	}
	for _, a := range []string{"--version", "version"} {
		var so bytes.Buffer
		if topLevel(&cli.Output{Stdout: &so, Stderr: &so}, "", []string{a}); so.String() != "kasbah (unstamped build)\n" {
			t.Errorf("unstamped %s: %q", a, so.String())
		}
	}
}

// Every command main dispatches is in the usage, and every `server`
// subcommand in both lists.
func TestUsageListsEveryCommand(t *testing.T) {
	u := usage("1.0.0")
	for _, c := range append(commands, "help") {
		if !strings.Contains(u, "\n  "+c+" ") {
			t.Errorf("usage does not list %s", c)
		}
	}
	for _, s := range serverSubcommands {
		if !strings.Contains(u, "\n  server "+s+" ") || !strings.Contains(serverUsage, "\n  "+s+" ") {
			t.Errorf("a usage does not list server %s", s)
		}
	}
}

// help <command> [sub…] is <command> [sub…] --help, so the two print the same;
// a topic, and a word that is no command, are help's own.
func TestHelpArgs(t *testing.T) {
	tests := []struct{ in, want []string }{
		{[]string{"help", "deploy"}, []string{"deploy", "--help"}},
		{[]string{"help", "server", "init"}, []string{"server", "init", "--help"}},
		{[]string{"help", "env", "set"}, []string{"env", "set", "--help"}},
		{[]string{"help", "version"}, []string{"version", "--help"}},
		{[]string{"help", "rules"}, []string{"help", "rules"}},
		{[]string{"help", "remote"}, []string{"help", "remote"}},
		{[]string{"help"}, []string{"help"}},
		{[]string{"help", "deploy\r"}, []string{"help", "deploy\r"}},
		{[]string{"deploy", "help"}, []string{"deploy", "help"}},
	}
	for _, tt := range tests {
		if got := helpArgs(tt.in); !slices.Equal(got, tt.want) {
			t.Errorf("helpArgs(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

// commands and serverSubcommands are what main.go and topLevel dispatch, read
// from their source: a dispatched command missing from commands would be an
// unknown topic to `kasbah help`. remote and the __ arms are internal.
func TestCommandsMatchDispatch(t *testing.T) {
	var cmds, subs []string
	fset := token.NewFileSet()
	for _, file := range []string{"main.go", "usage.go"} {
		f, err := parser.ParseFile(fset, file, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		ast.Inspect(f, func(n ast.Node) bool {
			sw, ok := n.(*ast.SwitchStmt)
			if !ok || !isArg(sw.Tag, 0) {
				return true
			}
			for _, st := range sw.Body.List {
				cc := st.(*ast.CaseClause)
				for _, e := range cc.List {
					c := strLit(e)
					if c == "" || c == "remote" || c == "help" || strings.HasPrefix(c, "__") || strings.HasPrefix(c, "-") {
						continue
					}
					if !slices.Contains(cmds, c) {
						cmds = append(cmds, c)
					}
					if c != "server" || file != "main.go" {
						continue
					}
					for _, b := range cc.Body {
						ast.Inspect(b, func(n ast.Node) bool {
							if be, ok := n.(*ast.BinaryExpr); ok && be.Op == token.EQL && isArg(be.X, 1) {
								if s := strLit(be.Y); s != "" && !slices.Contains(subs, s) {
									subs = append(subs, s)
								}
							}
							return true
						})
					}
				}
			}
			return true
		})
	}
	if !sameSet(cmds, commands) {
		t.Errorf("dispatched commands %q, commands %q", cmds, commands)
	}
	if !sameSet(subs, serverSubcommands) {
		t.Errorf("dispatched server subcommands %q, serverSubcommands %q", subs, serverSubcommands)
	}
	for _, c := range commands {
		if slices.Contains(help.Topics, c) {
			t.Errorf("command %s is also a help topic, which `kasbah help %s` would no longer reach", c, c)
		}
	}
}

// isArg is args[i].
func isArg(e ast.Expr, i int) bool {
	ix, ok := e.(*ast.IndexExpr)
	if !ok {
		return false
	}
	id, ok := ix.X.(*ast.Ident)
	return ok && id.Name == "args" && strLitInt(ix.Index) == i
}

func strLitInt(e ast.Expr) int {
	if b, ok := e.(*ast.BasicLit); ok && b.Kind == token.INT {
		if n, err := strconv.Atoi(b.Value); err == nil {
			return n
		}
	}
	return -1
}

func strLit(e ast.Expr) string {
	if b, ok := e.(*ast.BasicLit); ok && b.Kind == token.STRING {
		if s, err := strconv.Unquote(b.Value); err == nil {
			return s
		}
	}
	return ""
}

func sameSet(a, b []string) bool {
	a, b = slices.Clone(a), slices.Clone(b)
	slices.Sort(a)
	slices.Sort(b)
	return slices.Equal(a, b)
}

// Every `.Help(topic)` a failure carries is a literal `kasbah help` answers:
// a topic, a rule ID, or a command (a server subcommand after `server`).
func TestFailureHelpTopics(t *testing.T) {
	fset := token.NewFileSet()
	n := 0
	for _, dir := range []string{".", "../../internal"} {
		err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
			if err != nil || d.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
				return err
			}
			file, err := parser.ParseFile(fset, path, nil, 0)
			if err != nil {
				return err
			}
			ast.Inspect(file, func(node ast.Node) bool {
				call, ok := node.(*ast.CallExpr)
				if !ok {
					return true
				}
				if sel, ok := call.Fun.(*ast.SelectorExpr); !ok || sel.Sel.Name != "Help" || len(call.Args) != 1 {
					return true
				}
				n++
				lit, ok := call.Args[0].(*ast.BasicLit)
				if !ok || lit.Kind != token.STRING {
					t.Errorf("%s: .Help takes a string literal", fset.Position(call.Pos()))
					return true
				}
				topic, _ := strconv.Unquote(lit.Value)
				if !helpAnswers(topic) {
					t.Errorf("%s: kasbah help does not know %q", fset.Position(call.Pos()), topic)
				}
				return true
			})
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	if n == 0 {
		t.Error("no .Help call found: the scan is looking in the wrong place")
	}
	if helpAnswers("nope") || helpAnswers("server nope") || !helpAnswers("server init") || !helpAnswers("T05") {
		t.Error("helpAnswers does not tell topics apart")
	}
}

func helpAnswers(topic string) bool {
	words := strings.Fields(topic)
	switch {
	case len(words) == 2 && words[0] == "server":
		return slices.Contains(serverSubcommands, words[1])
	case len(words) != 1:
		return false
	case slices.Contains(commands, words[0]):
		return true
	}
	_, err := help.Topic("", topic)
	return err == nil
}
