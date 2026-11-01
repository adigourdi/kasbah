package env

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"slices"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/envtpl"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/serverlock"
	"github.com/adigourdi/kasbah/internal/state"
)

const setUsage = `Usage: kasbah env set KEY [USER@HOST] [--restart|--no-restart]

Changes one key of <apps>/<name>/.env on the server, every other line kept as
it is. KEY must be a key of the server's .env.prod.example; a KEY the .env
lacks is added where the template has it. The KASBAH_* keys are kasbah's own.

The value is never taken from the command line. On a terminal it is asked with
the typing hidden; without one it is read from stdin — one line, its newline
dropped:
  printf '%s' "$VALUE" | kasbah env set API_SECRET --no-restart

Flags:
  --restart     docker compose -p <name> up -d once .env is written
  --no-restart  leave the containers running the old value until the next deploy
Without either, a terminal is asked; without a terminal the run stops.
`

// SetUsage is `kasbah env set --help`.
func SetUsage() string { return setUsage }

// UpTimeout bounds a set that brings the project up: compose may pull.
const UpTimeout = 300

// maxValue is the most stdin may carry: one .env line, not a file.
const maxValue = 64 << 10

var envKey = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

var restartPair = prompt.Pair{Yes: "restart", No: "no-restart"}

// SetSession is one server, as `kasbah env set` needs it.
type SetSession interface {
	Marker() (*marker.Marker, error)
	// KeyState is `setup-env key`'s report and exit status.
	KeyState(dir, key string) (out string, rc int)
	// SetKey sends value on stdin; up, when set, is the compose project to
	// bring up after the write.
	SetKey(dir, key, value, up string) (out string, rc int)
	Close()
}

func parseSet(args []string) (Options, error) {
	o := Options{Set: true}
	var pos []string
	for _, a := range args {
		a = strings.TrimSuffix(a, "\r")
		switch {
		case a == "-h" || a == "--help":
			return o, ErrHelp
		case a == "--restart":
			if err := o.Restart.Set(prompt.Yes, restartPair, "env set"); err != nil {
				return o, err
			}
		case a == "--no-restart":
			if err := o.Restart.Set(prompt.No, restartPair, "env set"); err != nil {
				return o, err
			}
		case a == "--value" || strings.HasPrefix(a, "--value="):
			return o, cli.Fail("env set: the value is never taken from the command line — it would show in ps and the shell's history").Cont(
				"type it at the prompt, or pipe it on stdin: printf '%s' \"$VALUE\" | kasbah env set KEY --no-restart")
		case strings.HasPrefix(a, "-"):
			name, _, _ := strings.Cut(a, "=")
			return o, cli.Fail("env set: unknown flag '%s' (env set takes KEY, USER@HOST, --restart and --no-restart)", name)
		default:
			pos = append(pos, a)
		}
	}
	switch {
	case len(pos) == 0:
		return o, cli.Fail("env set: which key? — kasbah env set KEY [USER@HOST]")
	case len(pos) > 2:
		return o, cli.Fail("env set: too many arguments ('%s') — env set takes KEY and USER@HOST", pos[2])
	}
	o.Key = pos[0]
	if len(pos) == 2 {
		o.Target = pos[1]
	}
	if !envKey.MatchString(o.Key) {
		return o, cli.Fail("env set: '%s' is not an env key — letters, digits and _, not starting with a digit", o.Key)
	}
	if reserved(o.Key) {
		return o, cli.Fail("env set: %s is kasbah's own — the %s* keys are the managed block of .env, rewritten on every deploy from the server marker or kasbah.yml's resources: (docs/env-template.md)", o.Key, envtpl.ReservedPrefix)
	}
	return o, nil
}

// stdinValue is the value without a terminal: one line, one trailing
// newline (and CR) dropped.
func stdinValue(r io.Reader, key string) (string, error) {
	b, err := io.ReadAll(io.LimitReader(r, maxValue+1))
	if err != nil {
		return "", cli.Fail("env set: could not read the value for %s from stdin: %v", key, err)
	}
	if len(b) > maxValue {
		return "", cli.Fail("env set: the value for %s on stdin is over %d bytes — a .env value is one line. Nothing was changed.", key, maxValue)
	}
	v := strings.TrimSuffix(strings.TrimSuffix(string(b), "\n"), "\r")
	if v == "" {
		return "", cli.Fail("env set: no value for %s on stdin, and no terminal to ask on", key).Cont(
			"pipe it in: printf '%s' \"$VALUE\" | kasbah env set " + key + " --no-restart. Nothing was changed.")
	}
	return v, checkValue(key, v)
}

func checkValue(key, v string) error {
	if strings.ContainsAny(v, "\n\r\x00") {
		return cli.Fail("env set: the value for %s has a line break or a NUL in it — .env holds one line per key. Nothing was changed.", key)
	}
	return nil
}

func runSet(c Ctx, o Options) error {
	m, err := manifest.Require(manifest.File, c.Version)
	if err != nil {
		return err
	}
	target, _, err := state.Server(o.Target, "env set", "kasbah env set "+o.Key+" user@vps")
	if err != nil {
		return err
	}
	if o.Restart == prompt.Unset && !c.Prompter.TTY {
		return cli.Fail("env set: cannot ask whether to restart %s after setting %s: stdin is not a terminal", m.Name, o.Key).Cont(
			"pass --restart (docker compose -p "+m.Name+" up -d once .env is written) or --no-restart",
			"(the containers keep the old value until the next deploy). Nothing was changed.")
	}
	var value string
	if !c.Prompter.TTY {
		if value, err = stdinValue(c.Prompter.In, o.Key); err != nil {
			return err
		}
	}

	s, err := c.DialSet(target)
	if err != nil {
		return err
	}
	defer s.Close()
	mk, err := s.Marker()
	if err != nil {
		return err
	}
	dir := mk.AppsPath + "/" + m.Name
	out, rc := s.KeyState(dir, o.Key)
	if rc != 0 {
		return cli.Fail("could not read the env state of %s on %s", dir, target).Cont(
			"`kasbah remote setup-env key` failed: " + exitText(rc) + " (see above). Nothing was changed.")
	}
	kv := remote.KV([]byte(out))
	for _, k := range []string{"template_exists", "in_template", "env_exists"} {
		if _, ok := kv[k]; !ok {
			return cli.Fail("the key check on %s reported no %s — it was truncated, or the server's kasbah is not one this kasbah speaks to", target, k)
		}
	}
	switch {
	case kv["template_exists"] != "yes":
		return cli.Fail("%s has no %s/.env.prod.example, the template that says which keys .env holds", target, dir).Cont(
			"it reaches the server through the manifest's sync: list; `kasbah env "+target+"` ships it",
			"and renders .env from it. Nothing was changed.")
	case kv["in_template"] != "yes":
		return cli.Fail("%s is not a key of %s/.env.prod.example on %s", o.Key, dir, target).Cont(
			"env set changes a key the template declares. Add it to .env.prod.example, then",
			"`kasbah env "+target+"` ships the template and asks for the new key. Nothing was changed.")
	case kv["env_exists"] != "yes":
		return cli.Fail("%s has no %s/.env yet", target, dir).Cont(
			"`kasbah env " + target + "` renders it from the template first. Nothing was changed.")
	}
	if c.Prompter.TTY {
		if value, err = c.Prompter.Hidden(o.Key + " (typing hidden)"); err != nil {
			if e, ok := err.(*cli.Error); ok {
				return e.Cont("pipe the value on stdin instead: printf '%s' \"$VALUE\" | kasbah env set "+o.Key+" --no-restart",
					"Nothing was changed.")
			}
			return err
		}
		if err := checkValue(o.Key, value); err != nil {
			return err
		}
	}
	restart, err := c.Prompter.Choice(restartPair,
		fmt.Sprintf("Restart %s on %s once %s is set (docker compose -p %s up -d)?", m.Name, target, o.Key, m.Name), o.Restart)
	if err != nil {
		return err
	}
	up, limit := "", serverbin.RunTimeout
	if restart {
		up, limit = m.Name, UpTimeout
	}
	out, rc = s.SetKey(dir, o.Key, value, up)
	kv = remote.KV([]byte(out))
	if rc != 0 {
		why := "`kasbah remote setup-env set` failed: " + serverbin.ExitText(rc, limit) + " (see above)."
		if kv["set"] != "" {
			return cli.Fail("%s is set in %s/.env on %s, but docker compose -p %s up -d did not finish", o.Key, dir, target, m.Name).Cont(
				why, "The containers may still run the old value: deploy, or re-run with --restart.")
		}
		return cli.Fail("could not set %s in %s/.env on %s", o.Key, dir, target).Cont(why, "Nothing was changed.")
	}
	if kv["set"] == "" || restart && kv["restarted"] != "yes" {
		return cli.Fail("the set step on %s reported no outcome (raw output: %s)", target, strings.TrimSpace(out))
	}
	if err := state.Record(state.File, c.Version, "last_server", target); err != nil {
		return err
	}
	c.Out.Info("%s %s in %s/.env on %s", o.Key, kv["set"], dir, target)
	if restart {
		c.Out.Info("  restarted: docker compose -p %s up -d", m.Name)
	} else {
		c.Out.Info("  not restarted: the containers keep the old value until the next deploy")
	}
	return nil
}

// keyReport is `setup-env key DIR KEY`: whether the template and .env exist
// and whether the template declares KEY.
func keyReport(dir, key string) string {
	yes := func(b bool) string {
		if b {
			return "yes"
		}
		return "no"
	}
	tmpl, err := os.Stat(dir + "/.env.prod.example")
	hasTmpl := err == nil && tmpl.Mode().IsRegular()
	in := hasTmpl && !reserved(key) && slices.Contains(envtpl.Keys(dir+"/.env.prod.example"), key)
	env, err := os.Stat(dir + "/.env")
	hasEnv := err == nil && env.Mode().IsRegular()
	return "template_exists=" + yes(hasTmpl) + "\nin_template=" + yes(in) + "\nenv_exists=" + yes(hasEnv) + "\n"
}

// SetKey writes KEY=value into dir's .env through writeEnv: every assignment
// of KEY replaced in place (its CR kept), or a new line where the template
// puts KEY; every other line byte for byte. verb is "changed" or "added".
func SetKey(dir, key, value string) (verb string, err error) {
	tpath, epath := dir+"/.env.prod.example", dir+"/.env"
	if !envKey.MatchString(key) || reserved(key) {
		return "", fmt.Errorf("'%s' is not a key env set may change", key)
	}
	enc, err := Encode(value)
	if err != nil {
		return "", fmt.Errorf("%s: %v", key, err)
	}
	if fi, err := os.Stat(tpath); err != nil || !fi.Mode().IsRegular() {
		return "", fmt.Errorf("no %s to check %s against", tpath, key)
	}
	var tkeys []string
	for _, k := range envtpl.Keys(tpath) {
		if !reserved(k) && !slices.Contains(tkeys, k) {
			tkeys = append(tkeys, k)
		}
	}
	at := slices.Index(tkeys, key)
	if at < 0 {
		return "", fmt.Errorf("%s is not a key of %s", key, tpath)
	}
	fi, err := os.Stat(epath)
	if err != nil {
		return "", fmt.Errorf("no %s — `kasbah env` renders it first", epath)
	}
	if !fi.Mode().IsRegular() {
		return "", fmt.Errorf("%s is not a regular file", epath)
	}
	data, err := os.ReadFile(epath)
	if err != nil {
		return "", fmt.Errorf("cannot read %s", epath)
	}
	lines := rawLines(data)
	line := key + "=" + enc
	verb = "added"
	inBlock := managedBlock(lines)
	first, last := map[string]int{}, map[string]int{}
	for i, l := range lines {
		k, _, ok := envtpl.Assign(strings.TrimSuffix(l, "\r"))
		if !ok {
			if readsAs(strings.TrimSuffix(l, "\r"), key) {
				return "", fmt.Errorf("%s line %d sets %s in a form kasbah does not rewrite (KEY=value, one line, UTF-8) — fix that line by hand", epath, i+1, key)
			}
			continue
		}
		if k == key && inBlock[i] {
			return "", fmt.Errorf("%s line %d sets %s inside the kasbah managed block, which the next deploy rewrites without it — move it out of the block by hand", epath, i+1, key)
		}
		if k == key {
			nl := line
			if strings.HasSuffix(l, "\r") {
				nl += "\r"
			}
			lines[i], verb = nl, "changed"
		}
		if _, seen := first[k]; !seen {
			first[k] = i
		}
		last[k] = i
	}
	if verb == "added" {
		lines = slices.Insert(lines, insertAt(tkeys, at, first, last, len(lines)), line)
	}
	if err := writeEnv(epath, lines); err != nil {
		return "", fmt.Errorf("could not write %s: %v", epath, err)
	}
	return verb, nil
}

// readsAs is whether compose would read line as setting key though Assign
// does not: `KEY =v`, `KEY: v`, a byte that is not UTF-8.
func readsAs(line, key string) bool {
	t := strings.TrimLeft(line, " \t")
	if rest, ok := strings.CutPrefix(t, "export"); ok && strings.TrimLeft(rest, " \t") != rest {
		t = strings.TrimLeft(rest, " \t")
	}
	rest, ok := strings.CutPrefix(t, key)
	if !ok {
		return false
	}
	rest = strings.TrimLeft(rest, " \t")
	return strings.HasPrefix(rest, "=") || strings.HasPrefix(rest, ":")
}

// insertAt is where the template's tkeys[at] goes: after the last line of the
// nearest key before it in the template, else before the first of the nearest
// after it, else at the end.
func insertAt(tkeys []string, at int, first, last map[string]int, end int) int {
	for j := at - 1; j >= 0; j-- {
		if i, ok := last[tkeys[j]]; ok {
			return i + 1
		}
	}
	for j := at + 1; j < len(tkeys); j++ {
		if i, ok := first[tkeys[j]]; ok {
			return i
		}
	}
	return end
}

// SetHeader is the line ahead of the value on `setup-env set`'s stdin: its
// size and sha256, kept off argv where ps would show them.
func SetHeader(value string) string {
	size, sum := remote.Digest([]byte(value))
	return size + " " + sum + "\n"
}

// remoteSet is `setup-env set DIR KEY [--up=NAME]`, SetHeader then the value on
// stdin: under .deploy.lock and the shared server lock, as a deploy runs.
func remoteSet(dir, key, up string, stdin io.Reader, stdout, stderr io.Writer) int {
	fail := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "remote: env set: "+format+"\n", a...)
		return 1
	}
	if strings.HasPrefix(up, "-") {
		return fail("'%s' is not a compose project name", up)
	}
	in := bufio.NewReader(io.LimitReader(stdin, maxValue+200))
	header, err := in.ReadString('\n')
	size, sum, ok := strings.Cut(strings.TrimSuffix(header, "\n"), " ")
	if err != nil || !ok {
		return fail("no size and sha256 line ahead of the value on stdin — .env left untouched")
	}
	body, err := remote.Payload(in, size, sum)
	if err != nil {
		return fail("%v — .env left untouched", err)
	}
	if up != "" {
		if fi, err := os.Stat(dir + "/compose.yml"); err != nil || !fi.Mode().IsRegular() {
			return fail("no %s/compose.yml to bring up — .env left untouched", dir)
		}
	}
	lock, err := lockEnv(dir)
	if err != nil {
		return fail("%v", err)
	}
	defer lock.Close()
	sl, err := serverlock.Take(parent(dir), serverlock.Shared, "")
	if err != nil {
		return fail("%v", err)
	}
	if sl != nil {
		defer sl.Close()
	}
	verb, err := SetKey(dir, key, string(body))
	if err != nil {
		return fail("%v — .env left untouched", err)
	}
	fmt.Fprintf(stdout, "set=%s\n", verb)
	if up == "" {
		return 0
	}
	c := exec.Command("docker", "compose", "-p", up, "up", "-d")
	c.Env = append(os.Environ(), "LC_ALL=C")
	c.Dir = dir
	c.Stdout, c.Stderr = stderr, stderr
	if err := c.Run(); err != nil {
		return fail("docker compose -p %s up -d failed in %s", up, dir)
	}
	fmt.Fprintln(stdout, "restarted=yes")
	return 0
}
