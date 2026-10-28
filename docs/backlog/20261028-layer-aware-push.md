---
description: >
  Every build-push streams whole images, so an unchanged base layer crosses
  the uplink on every deploy and a 1 GB app image makes each release minutes
  long. The server already holds the layers: have `remote load` answer which
  diffIDs it has and filter those layer tarballs out of the `docker save`
  stream on the workstation, in internal/buildpush and internal/remote.
state: ready
priority: high
---

## Prompted by

Design review, 2026-10-28: "Whole images every build-push … is the thing that
makes people go back to a registry." Decided against adding skopeo — "our own
layer diff is simpler".

## Options

The agreed shape: workstation inspects the built images (`RootFS.Layers`) →
sends the diffID list → server answers what it already has, across every image
on the box → workstation runs `docker save` and a Go tar filter drops the layer
tarballs the server has, keeping `manifest.json` and configs → server-side
`docker load` accepts a tar whose missing layers are already in its store.
Same protocol shape as `remote sync`'s quick-check.

Trap: the real host runs the containerd image store, where ids differ from
overlay2's (`build-deploy.md` → versions.log `digest=`); the rig must prove
both stores before this ships.

## References

- `docs/build-deploy.md` → build-push Flow, "One `docker save` invocation carries every built image"
- `internal/buildpush`, `internal/remote`, `tests/integration/ship_test.sh`
