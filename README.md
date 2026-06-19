# incus-spawn-images

Custom Fedora base images for [incus-spawn](https://github.com/Sanne/incus-spawn).

These images are pre-baked with the static setup that `incus-spawn` normally performs at template build time, eliminating the dependency on the linuxcontainers.org image server and speeding up clean builds.

## What's baked in

- Fedora 44 minimal systemd rootfs
- `agentuser` (UID 1000) with passwordless sudo
- Base packages: git, curl, which, procps-ng, findutils, bash-completion
- 25+ unnecessary systemd services masked
- systemd-resolved disabled (incus-spawn uses gateway dnsmasq)
- nsswitch.conf patched for direct DNS
- Bloat packages removed (langpacks, geolite2)

## Building locally

```bash
# Build for current architecture
podman run --rm --privileged \
  -v "$(pwd):/build:ro" \
  -v "$(pwd)/output:/output" \
  -e OUTPUT_DIR=/output \
  fedora:44 bash /build/fedora/build.sh
```

## CI

GitHub Actions builds both x86_64 and aarch64 images. Releases are created on manual dispatch or monthly schedule.

## Using with incus-spawn

In `incus-spawn`'s `minimal.yaml`:

```yaml
image: fedora-44-base
image_url: https://github.com/Sanne/incus-spawn-images/releases/download/<tag>/fedora-44-{arch}.tar.xz
image_sha256:
  x86_64: <sha256>
  aarch64: <sha256>
```
