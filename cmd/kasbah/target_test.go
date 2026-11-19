package main

import (
	"errors"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/backup"
	"github.com/adigourdi/kasbah/internal/buildpush"
	"github.com/adigourdi/kasbah/internal/check"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/deploy"
	"github.com/adigourdi/kasbah/internal/destroy"
	"github.com/adigourdi/kasbah/internal/drop"
	"github.com/adigourdi/kasbah/internal/env"
	"github.com/adigourdi/kasbah/internal/history"
	"github.com/adigourdi/kasbah/internal/info"
	"github.com/adigourdi/kasbah/internal/mail"
	"github.com/adigourdi/kasbah/internal/migrate"
	"github.com/adigourdi/kasbah/internal/ops"
	"github.com/adigourdi/kasbah/internal/prune"
	"github.com/adigourdi/kasbah/internal/serverinit"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/status"
	"github.com/adigourdi/kasbah/internal/upgrade"
)

// stubUser makes ssh's config log in to every bare host as user, and records
// the lookups and the notes.
func stubUser(t *testing.T, user string) (looked, notes *[]string) {
	oldU, oldN := ssh.UserOf, ssh.Note
	var l, n []string
	ssh.UserOf = func(h string) (string, error) { l = append(l, h); return user, nil }
	ssh.Note = func(s string) { n = append(n, s) }
	t.Cleanup(func() { ssh.UserOf, ssh.Note = oldU, oldN })
	return &l, &n
}

// takesBareHost is every command whose grammar tells a bare host from its
// other positionals: each parse yields the target it resolved.
var takesBareHost = map[string]func(host string) (string, error){
	"server init": func(h string) (string, error) {
		o, err := serverinit.Parse([]string{h, "--no-mail", "--no-backup"})
		return o.Target, err
	},
	"server status":  func(h string) (string, error) { o, err := status.Parse([]string{h}); return o.Target, err },
	"server prune":   func(h string) (string, error) { o, err := prune.Parse([]string{h, "--yes"}); return o.Target, err },
	"server destroy": func(h string) (string, error) { o, err := destroy.Parse([]string{h}); return o.Target, err },
	"server upgrade-traefik": func(h string) (string, error) {
		o, err := upgrade.Parse([]string{h, "--version=v3.7.10"})
		return o.Target, err
	},
	"server backup-prune": func(h string) (string, error) { o, err := backup.ParsePrune([]string{h}); return o.Target, err },
	"server mail-setup-guide": func(h string) (string, error) {
		o, err := mail.Parse("mail-setup-guide", []string{h})
		return o.Target, err
	},
	"migrate server": func(h string) (string, error) {
		o, err := migrate.Parse([]string{"server", h})
		return o.Target, err
	},
	"info":       func(h string) (string, error) { o, err := info.Parse([]string{h}); return o.Target, err },
	"check":      func(h string) (string, error) { o, err := check.Parse([]string{"--server", h}); return o.Server, err },
	"check=":     func(h string) (string, error) { o, err := check.Parse([]string{"--server=" + h}); return o.Server, err },
	"build-push": func(h string) (string, error) { o, err := buildpush.Parse([]string{h}); return o.Target, err },
	"env":        func(h string) (string, error) { o, err := env.Parse([]string{h}); return o.Target, err },
	"env set":    func(h string) (string, error) { o, err := env.Parse([]string{"set", "KEY", h}); return o.Target, err },
	"backup":     func(h string) (string, error) { o, err := deploy.ParseBackup([]string{h}); return o.Target, err },
	"restore": func(h string) (string, error) {
		o, err := deploy.ParseRestore([]string{h, "--list"})
		return o.Target, err
	},
	"drop":    func(h string) (string, error) { o, err := drop.Parse([]string{h, "--prune"}); return o.Target, err },
	"history": func(h string) (string, error) { o, err := history.Parse("history", []string{h}); return o.Target, err },
	"changelog": func(h string) (string, error) {
		o, err := history.Parse("changelog", []string{h})
		return o.Target, err
	},
	// Two bare words beside each other: the server, then the service.
	"logs": func(h string) (string, error) { o, err := ops.Parse("logs", []string{h, "web"}); return o.Target, err },
	"exec": func(h string) (string, error) {
		o, err := ops.Parse("exec", []string{h, "web", "--", "true"})
		return o.Target, err
	},
	"server add-mail-domain": func(h string) (string, error) {
		o, err := mail.Parse("add-mail-domain", []string{h, "shop.test"})
		return o.Target, err
	},
	"server mail-dkim": func(h string) (string, error) {
		o, err := mail.Parse("mail-dkim", []string{h, "shop.test", "--keep-keys"})
		return o.Target, err
	},
}

// takesHostOrVersion is every command whose other positional is a version:
// one shaped like a version is the version, and any other the server.
var takesHostOrVersion = map[string]func(args ...string) (string, string, error){
	"deploy": func(a ...string) (string, string, error) { o, err := deploy.Parse(a); return o.Target, o.Version, err },
	"rollback": func(a ...string) (string, string, error) {
		o, err := deploy.ParseRollback(a)
		return o.Target, o.Version, err
	},
	"pending": func(a ...string) (string, string, error) {
		o, err := history.Parse("pending", a)
		return o.Target, o.Version, err
	},
}

func TestBareHostResolved(t *testing.T) {
	for name, parse := range takesBareHost {
		looked, notes := stubUser(t, "alice")
		got, err := parse("vps")
		if err != nil || got != "alice@vps" {
			t.Errorf("%s vps: %q, %v", name, got, err)
		}
		if len(*looked) != 1 || len(*notes) != 1 || (*notes)[0] != "kasbah: as alice@vps (user from ssh config)" {
			t.Errorf("%s vps: looked up %q, noted %q — want one of each", name, *looked, *notes)
		}
		looked, notes = stubUser(t, "alice")
		if got, err := parse("bob@vps"); err != nil || got != "bob@vps" || len(*looked)+len(*notes) != 0 {
			t.Errorf("%s bob@vps: %q, %v, looked up %q", name, got, err, *looked)
		}
		stubUser(t, "root")
		_, err = parse("vps")
		var e *cli.Error
		if !errors.As(err, &e) || !strings.Contains(err.Error(), "as root") || !strings.Contains(strings.Join(e.NextLines(), " "), "root@vps") {
			t.Errorf("%s vps as root: %v", name, err)
		}
		stubUser(t, "root")
		if got, err := parse("root@vps"); err != nil || got != "root@vps" {
			t.Errorf("%s root@vps: %q, %v", name, got, err)
		}
		// A bare version is a misread one, never a host; a dotted quad is a host.
		looked, _ = stubUser(t, "alice")
		for _, v := range []string{"1.2.0", "v1.2.0", "1.2.0-rc.1"} {
			_, err = parse(v)
			if !errors.As(err, &e) || !strings.Contains(err.Error(), "'"+v+"' reads as a version") || !strings.Contains(err.Error(), "takes no version") ||
				!strings.Contains(strings.Join(e.NextLines(), " "), "USER@"+v) {
				t.Errorf("%s %s: %v", name, v, err)
			}
		}
		if len(*looked) != 0 {
			t.Errorf("%s: looked up a version: %q", name, *looked)
		}
		if got, err := parse("10.0.0.1"); err != nil || got != "alice@10.0.0.1" {
			t.Errorf("%s 10.0.0.1: %q, %v", name, got, err)
		}
	}
}

// The domain is checked before the server is looked up, so a swapped pair
// whose host has no dot fails on it as a domain and asks ssh nothing.
func TestMailDomainBeforeServer(t *testing.T) {
	looked, notes := stubUser(t, "alice")
	for _, cmd := range []string{"add-mail-domain", "mail-dkim"} {
		_, err := mail.Parse(cmd, []string{"shop.test", "vps"})
		var e *cli.Error
		if !errors.As(err, &e) || !strings.Contains(err.Error(), "'vps' is not a domain name") ||
			!strings.Contains(strings.Join(e.NextLines(), " "), "kasbah server "+cmd+" vps shop.test") {
			t.Errorf("%s shop.test vps: %v", cmd, err)
		}
		if _, err := mail.Parse(cmd, []string{"vps"}); err == nil || !strings.Contains(err.Error(), "a domain is required") {
			t.Errorf("%s vps: %v", cmd, err)
		}
		if o, err := mail.Parse(cmd, []string{"bob@vps", "shop.test"}); err != nil || o.Target != "bob@vps" {
			t.Errorf("%s bob@vps: %+v %v", cmd, o, err)
		}
	}
	if len(*looked)+len(*notes) != 0 {
		t.Errorf("looked up %q, noted %q", *looked, *notes)
	}
}

func TestHostOrVersion(t *testing.T) {
	for name, parse := range takesHostOrVersion {
		looked, notes := stubUser(t, "alice")
		for _, args := range [][]string{{"vps"}, {"vps", "1.2.0"}, {"1.2.0", "vps\r"}} {
			*looked, *notes = nil, nil
			target, _, err := parse(args...)
			if err != nil || target != "alice@vps" || len(*looked) != 1 || len(*notes) != 1 ||
				(*notes)[0] != "kasbah: as alice@vps (user from ssh config)" {
				t.Errorf("%s %q: %q, %v, looked up %q, noted %q — want one of each", name, args, target, err, *looked, *notes)
			}
		}
		// A version-shaped bare word is the version, never looked up.
		looked, notes = stubUser(t, "alice")
		for _, v := range []string{"1.2.0", "1.2.0-rc.1"} {
			if target, version, err := parse(v); err != nil || target != "" || version != v {
				t.Errorf("%s %s: %q %q %v", name, v, target, version, err)
			}
		}
		if target, version, err := parse("1.2.3", "you@vps"); err != nil || target != "you@vps" || version != "1.2.3" {
			t.Errorf("%s 1.2.3 you@vps: %q %q %v", name, target, version, err)
		}
		if _, _, err := parse("v1.2.0"); err == nil || !strings.Contains(err.Error(), "write the version without the 'v'") {
			t.Errorf("%s v1.2.0: %v", name, err)
		}
		for _, args := range [][]string{{"vps", "bob@vps"}, {"vps", "rpi"}, {"bob@vps", "rpi"}} {
			_, _, err := parse(args...)
			var e *cli.Error
			if !errors.As(err, &e) || !strings.Contains(err.Error(), "two servers given") || len(e.NextLines()) == 0 {
				t.Errorf("%s %q: %v", name, args, err)
			}
		}
		// Near a version is a mistyped one, refused even beside a server.
		for _, args := range [][]string{{"1.2"}, {"1"}, {"v1.2"}, {"1.2.3.4.5"}, {"vps", "1.2"}, {"bob@vps", "v1"}} {
			_, _, err := parse(args...)
			bad := args[len(args)-1]
			var e *cli.Error
			if !errors.As(err, &e) || !strings.Contains(err.Error(), "'"+bad+"' is not a version kasbah can use") ||
				!strings.Contains(strings.Join(e.NextLines(), " "), "USER@"+bad) {
				t.Errorf("%s %q: %v", name, args, err)
			}
		}
		if _, _, err := parse("vps:2222"); err == nil || !strings.Contains(err.Error(), "invalid ssh host 'vps:2222'") {
			t.Errorf("%s vps:2222: %v", name, err)
		}
		if len(*looked)+len(*notes) != 0 {
			t.Errorf("%s: looked up %q, noted %q", name, *looked, *notes)
		}
		for _, h := range []string{"10.0.0.1", "1.2.3.4", "v2.example.com"} {
			*looked = nil
			if target, version, err := parse(h); err != nil || target != "alice@"+h || version != "" || len(*looked) != 1 {
				t.Errorf("%s %s: %q %q %v, looked up %q", name, h, target, version, err, *looked)
			}
		}
		stubUser(t, "root")
		_, _, err := parse("vps")
		var e *cli.Error
		if !errors.As(err, &e) || !strings.Contains(err.Error(), "as root") || !strings.Contains(strings.Join(e.NextLines(), " "), "root@vps") {
			t.Errorf("%s vps as root: %v", name, err)
		}
		if target, _, err := parse("root@vps"); err != nil || target != "root@vps" {
			t.Errorf("%s root@vps: %q %v", name, target, err)
		}
	}
}

// --build-only connects nowhere, so its server is neither looked up nor refused.
func TestBuildOnlyNotResolved(t *testing.T) {
	looked, notes := stubUser(t, "root")
	if o, err := buildpush.Parse([]string{"vps", "--build-only"}); err != nil || o.Target != "vps" || !o.BuildOnly {
		t.Errorf("build-push vps --build-only: %+v %v", o, err)
	}
	if len(*looked)+len(*notes) != 0 {
		t.Errorf("looked up %q, noted %q", *looked, *notes)
	}
}

// A lone bare word where logs' or exec's service stands is left for the run,
// which reads compose.prod.yml; changelog takes no version at all.
func TestBareWordUndecided(t *testing.T) {
	looked, _ := stubUser(t, "alice")
	if o, err := ops.Parse("logs", []string{"vps"}); err != nil || o.Word != "vps" || o.Service != "" || o.Target != "" {
		t.Errorf("logs vps: %+v %v", o, err)
	}
	if o, err := ops.Parse("exec", []string{"vps", "--", "true"}); err != nil || o.Word != "vps" || o.Service != "" || o.Target != "" {
		t.Errorf("exec vps: %+v %v", o, err)
	}
	if o, err := ops.Parse("logs", []string{"web", "bob@vps"}); err != nil || o.Service != "web" || o.Target != "bob@vps" {
		t.Errorf("logs web bob@vps: %+v %v", o, err)
	}
	if _, err := history.Parse("changelog", []string{"1.2.3"}); err == nil || !strings.Contains(err.Error(), "takes no version") {
		t.Errorf("changelog 1.2.3: %v", err)
	}
	for _, cmd := range []string{"history", "changelog"} {
		if _, err := history.Parse(cmd, []string{"1.2"}); err == nil || !strings.Contains(err.Error(), "'1.2' is not a version kasbah can use") {
			t.Errorf("%s 1.2: %v", cmd, err)
		}
	}
	if len(*looked) != 0 {
		t.Errorf("looked up %q", *looked)
	}
}
