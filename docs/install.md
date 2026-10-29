# Installing kasbah

kasbah runs on a **Linux** or **macOS** workstation, amd64 or arm64; on Linux the
same binary is what it ships to every server, and a macOS install carries the two
Linux server builds beside its own (`overview.md` → Distribution). The macOS
build is cross-compiled and unit-tested but has not yet been run on a Mac. Every
install path ends in the same place:

- `~/.local/share/kasbah/<version>/` (`KASBAH_LIB_DIR`, else
  `$XDG_DATA_HOME/kasbah` when that is set) holds each installed
  version — the binary, and beside it `server/kasbah-linux-<arch>`, what that
  version ships to a server. Every release installed stays; at most one dev
  build sits beside them.
- `~/.local/bin/kasbah` (`KASBAH_BIN_DIR`) is a symlink to the newest installed
  version that runs, or to the one a version argument resolved to. A command handed a
  project or server that wants another installed version re-runs under it
  (`cli.md` → Hand-off between installed versions).

Nothing needs root, and nothing edits a shell profile; when `~/.local/bin` is not
on `PATH`, the installer says so.

## From a release: `get.sh`

```sh
curl -fsSL https://github.com/adigourdi/kasbah/releases/latest/download/get.sh | sh
curl -fsSL https://github.com/adigourdi/kasbah/releases/latest/download/get.sh | sh -s -- v1
```

| Argument | Installs |
|---|---|
| none | the release `get.sh` came from — from `latest`, the newest |
| `vN` / `vN.M` | the newest release of that major / minor |
| `vN.M.P` | that release (the `v` is optional; `-rc.K` too) |
| `--pre` | with `vN` / `vN.M`, lets a pre-release (`-rc.N`) be picked |
| `--yes` | moves `~/.local/bin/kasbah` to another major without asking |

`~/.local/bin/kasbah` then points at the release installed, even when a newer
one is already there. A malformed version, or `--pre` without one, is a usage
error before anything is downloaded.

`get.sh` is a POSIX `sh` script (dash, busybox ash) carrying the version of the
release it belongs to. It downloads that release's `kasbah_<ver>_linux_<arch>` —
on a Mac `kasbah_<ver>_darwin_<arch>` plus both `kasbah_<ver>_linux_*` server
builds, an Apple Silicon Mac under Rosetta getting the arm64 build —
`checksums.txt` and `checksums.txt.minisig`, checks every download's sha256 — and
the signature too when `minisign` is installed — checks the binary runs, then
hands off to `kasbah self-update` *run from the download*. For its own release
(no argument, or that version named) it passes `--from` the downloaded files:
the binary verifies the signature with the key built into it and installs its
own bytes, with no GitHub API call at all. For another version, `self-update`
resolves it through the releases API and downloads it (`cli.md` → `kasbah self-update`).
Prompts read the terminal (`/dev/tty`), never the piped script.

Downloads try, in order, and a failure lists what each said:

1. `curl` (or `wget`) from `https://github.com/adigourdi/kasbah/releases/download/v<ver>/`;
2. `curl` with a token — `GITHUB_TOKEN`, else `gh auth token --hostname github.com`
   — through the releases API; the token goes to the API host only (the redirect
   to the storage host is followed without it) and never onto a command line;
3. `gh release download`.

The second and third serve a private repository; on a public one the first
always answers.

It refuses, running nothing:

- a machine that is not Linux or macOS on x86_64/amd64 or aarch64/arm64;
- a sha256 that does not match `checksums.txt`, or no `sha256sum`/`shasum` to check it;
- a temp dir it cannot execute from (`/tmp` mounted `noexec`): set `TMPDIR` to
  one that allows execution;
- an https download through a busybox `wget` that does not check TLS
  certificates, unless `minisign` verified the signature: install `curl` or `minisign`.

Exit `2` is a usage error, `1` a refusal; otherwise the exit status is
`self-update`'s. `KASBAH_BIN_DIR` and `KASBAH_LIB_DIR` pass through.
`KASBAH_GET_VERSION`, `KASBAH_GET_BASE` and `KASBAH_RELEASES_API` point it
elsewhere (tests).

## From a release, by hand

For a verification that does not rest on the script or on the binary checking
itself — `release.pub`'s key obtained separately (the repository, this page):

```sh
ver=1.1.0 arch=amd64                       # arm64 on an arm64 machine
gh release download "v$ver" --repo adigourdi/kasbah \
  -p "kasbah_${ver}_linux_${arch}" -p checksums.txt -p checksums.txt.minisig
minisign -Vm checksums.txt -P RWS3pRJJwM6L/B8Sp/FgiS4cUxJlSnceHOFLZIKsXPaE7LYtWA4ROLt8
sha256sum -c --ignore-missing checksums.txt
chmod +x "kasbah_${ver}_linux_${arch}"
"./kasbah_${ver}_linux_${arch}" self-update "v$ver"
```

On a Mac, download `kasbah_${ver}_darwin_${arch}` and both
`kasbah_${ver}_linux_amd64`/`_arm64`, check them with `shasum -a 256 -c
--ignore-missing checksums.txt`, and run the darwin one with `self-update
"v$ver" --from .` so it installs the two server builds from the same directory.

`curl -fLO https://github.com/adigourdi/kasbah/releases/download/v$ver/<asset>`
fetches the same files without `gh` once the repository is public. The last line
installs the binary's own bytes, verified once more against the signed checksums.

## Updating: `kasbah self-update`

`kasbah self-update [vN | vN.M | vN.M.P] [--pre] [--yes]` installs a release
beside the others; no argument is the newest of the running kasbah's major.
Up to date, it downloads nothing and exits 0. A token is optional — required only
while the repository is private (`cli.md` → `kasbah self-update`).

## From source: `install-dev.sh`

From a checkout, with Docker (the Go toolchain runs in `compose.yml`'s container):

```sh
./install-dev.sh            # this working tree: a dev build
./install-dev.sh v1         # the newest local v1.* tag, built from source
```

No argument builds the working tree and installs it as **the** dev build — the
previous dev build is removed, releases stay. `vN | vN.M | vN.M.P [--pre]` picks
a local tag (`git fetch --tags` first), clones it to a temporary directory and
builds it with that tag's own toolchain: the result is byte-identical to the
published release, and `~/.local/bin/kasbah` points at it. The
working tree is built first either way — its binary resolves the tag and
installs the result. `KASBAH_SKIP_BUILD=1` installs the `dist/` already built.
Unlike `self-update`, it moves `~/.local/bin/kasbah` across majors without asking:
the install is the request.

## What each path trusts

- **`get.sh`** trusts HTTPS to GitHub, as any `curl | sh` does: the script, the
  binary and `checksums.txt` come from the same place. The signature check that
  follows is the downloaded binary's own unless `minisign` is installed.
- **Every later `self-update`** trusts the key compiled into the installed
  binary: a release not signed by it is refused, whoever controls the download.
  That pinning is what the signature buys.
- **The by-hand path** trusts only `release.pub`'s key, checked with your own
  `minisign` before anything runs.
- **`install-dev.sh vN | vN.M | vN.M.P`** trusts the checkout's tag and the pinned toolchain
  image; its hashes can be compared to the release's `checksums.txt`.

## Uninstalling

```sh
rm -rf ~/.local/share/kasbah ~/.local/bin/kasbah
```

(or the `KASBAH_LIB_DIR` / `$XDG_DATA_HOME/kasbah` / `KASBAH_BIN_DIR` in use). Servers are separate:
`kasbah server destroy` de-brands one (`cli.md`).
