---
description: >
  On a workstation using Docker's containerd image store — the default for
  fresh Docker Engine 29 installs and Docker Desktop — `docker save` names
  layer blobs by their compressed digest, so build-push's layer filter matches
  nothing and every push ships whole images. Map each layer's diffID to its
  saved blob name before the stream, in internal/buildpush.
state: ready
priority: high
---

## Prompted by

Review of `layer-aware-push` (2026-10-29), verified on a containerd-store
dind (docker 29.2.1): a built layer with diffID `8d3a23ff…` is saved as
`blobs/sha256/d864fce…`; pulled `alpine:3.22`'s `be64570a…` as `63e7e496…`.
"Docker Engine 29 fresh installs and Docker Desktop default to that store" —
so for most new users the layer-aware push saves nothing.

## Options

- Read the image manifests from the local store before saving (the containerd
  store exposes each image's manifest and config by digest — e.g. through the
  engine API's image inspect `Descriptor`, then the manifest's `layers[]`
  digests in order, paired with the config's `rootfs.diff_ids`) and filter by
  those blob names.
- Or buffer only `index.json`/manifests: not possible in one pass — `docker
  save` writes blobs before them.

## References

- `internal/buildpush/{filter.go,layers.go,ship.go}`, `docs/build-deploy.md`
  → "Only the layers the server lacks cross the wire"
