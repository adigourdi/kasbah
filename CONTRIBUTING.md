# Contributing to kasbah

kasbah is built spec-first. The files in [docs/](docs/README.md) describe what
the tool does: a change in behaviour updates the document that describes it,
and the tests that prove it, in the same commit.

## Building

Only Docker is needed on the host. The Go toolchain runs in a container
defined by `compose.yml`, which pins its version. The container writes as uid
1000 unless told otherwise; the repo's scripts pass yours, and by hand
`env UID="$(id -u)" GID="$(id -g)" docker compose …` does the same.

```sh
docker compose run --rm build   # dist/kasbah, the server binaries in dist/server/, the macOS builds in dist/darwin/, dist/yaml2json (test helper)
KASBAH_GOOS=darwin docker compose run --rm build   # on a Mac: dist/kasbah and dist/yaml2json as darwin builds (test.sh and install-dev.sh set it)
dist/kasbah --help              # run the build straight from the checkout
./install-dev.sh                # or install it as your kasbah (docs/install.md)
```

For a faster loop, keep a toolchain container running:

```sh
docker compose up -d dev
docker compose exec dev go test ./...
```

Build from the main checkout rather than a git worktree: the version stamp is
read from git, and a worktree's `.git` points outside the mounted directory.

## Testing

```sh
./test.sh
```

It runs `go vet`, the `gofmt` check and `go test`, builds `dist/`, then runs the
black-box suites in `tests/` against that build. It must pass before every
commit. Besides Docker, the suites use `git`, `jq`, GNU `diff` and `patch`,
`python3`, `openssl`, `dash`, `curl`, `wget`, `sha256sum`, `shasum` (perl) and
util-linux's `script` and `setsid`.

Each suite prints one line; its full output is in `.cache/test-logs/`, and is
shown when it fails. `KASBAH_TEST_VERBOSE=1` streams everything;
`KASBAH_BIN=<path>` tests that binary instead of building one; the suites still
read YAML through this checkout's `dist/yaml2json`, so run the build once first.

The integration tests run against the rig, a container that plays a VPS
([tests/rig/README.md](tests/rig/README.md)). They take much longer:

```sh
tests/rig/rig.sh up
KASBAH_RIG_TESTS=1 ./test.sh
```

## Making a change

- Behaviour and its documentation change together: when the code and a
  document in `docs/` disagree, the change that settles it fixes the document.
- Tests land in the same change as the code they cover.
- The conventions every change follows, and the names that are frozen, are in
  [CLAUDE.md](CLAUDE.md).
- `docs/` describes kasbah as it stands; what is intended lives in `plan/`:
  the build plan in [plan/roadmap/](plan/roadmap/README.md), ideas not yet
  planned in [plan/backlog/](plan/backlog/).

## Releasing

For maintainers. Releases are GitHub Releases cut from a local checkout.

```sh
./release.sh keygen     # once: the signing key pair; commit release.pub
./release.sh v1.2.3     # tag, test, build twice, sign, publish
```

The release commit sets `VERSION` to the new number: a patch for fixes, a
minor for additive features, a major for a schema change. `./release.sh` needs
that commit pushed and the tree clean, `gh` authenticated, and a terminal for
the key's password; a `-rc.N` suffix makes a pre-release. What a release
contains and how builds are versioned: [docs/overview.md](docs/overview.md)
(Distribution) and the header of `release.sh`.
