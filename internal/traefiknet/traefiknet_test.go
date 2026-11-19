package traefiknet

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// fake answers network ls with nets and inspect with on, logging each call.
func fake(nets, on string, inspectErr error, calls *[]string) Docker {
	return func(args ...string) (string, error) {
		j := strings.Join(args, " ")
		*calls = append(*calls, j)
		switch {
		case strings.HasPrefix(j, "network ls"):
			return nets, nil
		case args[0] == "inspect":
			return on, inspectErr
		}
		return "", nil
	}
}

func TestNetworksFilters(t *testing.T) {
	var calls []string
	got, err := fake("b_kasbah a\r\na_kasbah a\n", "", nil, &calls).Networks("a")
	if err != nil || strings.Join(got, " ") != "a_kasbah b_kasbah" {
		t.Fatalf("%v %v", got, err)
	}
	if calls[0] != "network ls --filter label=com.docker.compose.network=kasbah --filter label=com.docker.compose.project=a --format {{.Name}} {{.Label \"com.docker.compose.project\"}}" {
		t.Fatalf("%q", calls[0])
	}
	calls = nil
	fake("", "", nil, &calls).Served(t.TempDir())
	if strings.Contains(calls[0], "label=com.docker.compose.project") {
		t.Fatalf("every project's, unfiltered: %q", calls[0])
	}
}

// Served keeps the mail stack's and each project's with a directory under
// apps; a hand-run compose project on the host is never joined.
func TestServedScopesToApps(t *testing.T) {
	apps := t.TempDir()
	os.Mkdir(filepath.Join(apps, "a"), 0o755)
	os.WriteFile(filepath.Join(apps, "f"), nil, 0o644)
	var calls []string
	got, err := fake("a_kasbah a\nmail_kasbah mail\nhand_kasbah hand\nf_kasbah f\nodd_kasbah ../a\nbare_kasbah\n", "", nil, &calls).Served(apps)
	if err != nil || strings.Join(got, " ") != "a_kasbah mail_kasbah" {
		t.Fatalf("%v %v", got, err)
	}
}

func TestJoinIsIdempotent(t *testing.T) {
	var calls []string
	apps := t.TempDir()
	os.Mkdir(filepath.Join(apps, "a"), 0o755)
	os.Mkdir(filepath.Join(apps, "b"), 0o755)
	d := fake("a_kasbah a\nb_kasbah b\n", "traefik_default\na_kasbah\n", nil, &calls)
	all, joined, err := d.JoinAll(apps)
	if err != nil || strings.Join(all, " ") != "a_kasbah b_kasbah" || strings.Join(joined, " ") != "b_kasbah" {
		t.Fatalf("%v %v %v", all, joined, err)
	}
	if n := strings.Count(strings.Join(calls, "\n"), "network connect"); n != 1 || calls[len(calls)-1] != "network connect b_kasbah traefik" {
		t.Fatalf("%q", calls)
	}
	if _, _, err := fake("mail_kasbah mail\n", "", errors.New("Error: No such object: traefik"), &calls).JoinAll(apps); !errors.Is(err, ErrNoTraefik) {
		t.Fatalf("no traefik to join: %v", err)
	}
}

func TestLeave(t *testing.T) {
	var calls []string
	done, err := fake("", "traefik_default\na_kasbah\n", nil, &calls).Leave([]string{"a_kasbah", "c_kasbah"})
	if err != nil || strings.Join(done, " ") != "a_kasbah" || calls[len(calls)-1] != "network disconnect a_kasbah traefik" {
		t.Fatalf("%v %v %q", done, err, calls)
	}
	if done, err := fake("", "", errors.New("Error: No such object: traefik"), &calls).Leave([]string{"a_kasbah"}); err != nil || done != nil {
		t.Fatalf("no traefik leaves nothing to do: %v %v", done, err)
	}
}

// shared is a docker whose kasbah-net exists unless gone, with each
// container's `name mode nets…` line; rm is logged.
func shared(gone bool, containers string, calls *[]string) Docker {
	return func(args ...string) (string, error) {
		j := strings.Join(args, " ")
		switch {
		case strings.HasPrefix(j, "network inspect"), j == "network rm kasbah-net":
			if gone {
				return "", errors.New("Error response from daemon: network kasbah-net not found")
			}
			*calls = append(*calls, j)
			return "kasbah-net\n", nil
		case j == "ps -aq":
			return strings.Repeat("id\n", strings.Count(containers, "\n")), nil
		case args[0] == "inspect":
			return containers, nil
		}
		return "", errors.New("unexpected docker " + j)
	}
}

func TestDropShared(t *testing.T) {
	var calls []string
	if said, err := shared(true, "", &calls).DropShared(); said != "" || err != nil || len(calls) != 0 {
		t.Errorf("gone: %q %v %q", said, err, calls)
	}
	// A stopped container created on it, and one disconnected from it while
	// it ran, still need it to start.
	said, err := shared(false, "/traefik traefik_default traefik_default a_kasbah\r\n/old-db-1 kasbah-net \n/old-web-1 kasbah-net old_default \n/legacy bridge kasbah-net \n", &calls).DropShared()
	if err != nil || said != "kasbah-net kept: legacy, old-db-1, old-web-1 still on it" || slices.Contains(calls, "network rm kasbah-net") {
		t.Errorf("in use: %q %v %q", said, err, calls)
	}
	calls = nil
	said, err = shared(false, "/traefik traefik_default traefik_default a_kasbah\n", &calls).DropShared()
	if err != nil || said != "kasbah-net removed: no container is on it" || calls[len(calls)-1] != "network rm kasbah-net" {
		t.Errorf("unused: %q %v %q", said, err, calls)
	}
	if _, err := Docker(func(...string) (string, error) {
		return "", errors.New(`exec: "docker": executable file not found in $PATH`)
	}).DropShared(); err == nil {
		t.Error("a docker that does not run is not a network that is gone")
	}
	if !NoNetwork(errors.New("Error: No such network: kasbah-net"), Shared) || NoNetwork(errors.New("Error response from daemon: network kasbah-net2 not found"), "kasbah-net2x") {
		t.Error("NoNetwork")
	}
}
