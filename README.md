# incus-spawn-images

Custom Fedora base images for [incus-spawn](https://github.com/Sanne/incus-spawn).

These images are pre-baked with the static setup that `incus-spawn` would
otherwise perform at template build time. Baking it in once means clean builds
no longer depend on the linuxcontainers.org image server and skip the repeated
per-build provisioning, so spinning up a fresh container is faster and more
reproducible.

## What's baked in

The image is a Fedora 44 systemd rootfs bootstrapped directly with
`dnf --installroot` (see [`fedora/build.sh`](fedora/build.sh)).

**Packages.** Installed with weak dependencies off (`install_weak_deps=False`)
and without docs (`tsflags=nodocs`) to keep the image small:

- Core: `systemd`, `systemd-udevd`, `sudo`, `bash`, `coreutils`, `util-linux`, `passwd`, `dnf5`
- DNS/net tooling: `dhcpcd`, `iproute`, `iputils`
- Locale: `glibc-langpack-en`
- Dev/agent basics: `git`, `curl`, `which`, `procps-ng`, `findutils`, `bash-completion`

The kernel (`kernel*`) is **excluded** — containers share the host kernel, so
shipping one wastes space. Bloat that the base pulls in anyway
(`glibc-all-langpacks`, `geolite2-city`, `geolite2-country`) is removed after
install, and `/usr/share/doc`, `man`, `info`, `licenses`, and `groff` are
stripped.

**`agentuser` (UID 1000).** Created with passwordless sudo, added to the
`systemd-journal` group (so it can read logs), given a `~/inbox` directory, and
a `.bashrc` that sets the terminal window title to `isx:<hostname>` and sources
bash-completion.

**Networking.** The image carries no `systemd-resolved`:

- DHCP is handled by a small custom `dhcpcd-eth0.service` that runs
  `dhcpcd -4 -q eth0`, naming the interface explicitly. Without this the
  container would boot with no IPv4 address.
- `nsswitch.conf` has the mDNS `resolve` entry stripped so `.local` names go to
  `incus-spawn`'s gateway dnsmasq instead of multicast DNS.
- `/etc/resolv.conf` is removed (rather than left as a dangling
  `systemd-resolved` symlink); `incus-spawn`'s `BuildCommand` writes the real
  one at container start.

`systemd-udevd` *is* installed: without it, host-managed device nodes like
`/dev/net/tun` and `/dev/fuse` can't be `fchmod`'d from inside the container's
user namespace, which breaks `%triggerin` scriptlets (e.g. `openssh-server`)
during package installs in derived templates.

**Trimmed systemd units.** ~19 services/timers that are useless or harmful in a
container are masked — `systemd-homed`, the `systemd-pcrlock-*` and
`systemd-tpm2-clear` TPM units, time sync (`timesyncd`, `time-wait-sync`),
`systemd-boot-*` and `systemd-sysupdate*`, `unbound-anchor.timer`,
`fstrim.timer`, and `selinux-autorelabel-mark`.

**Packaging.** The output is an Incus unified tarball: `metadata.yaml` plus the
rootfs under a `rootfs/` subdirectory, compressed as `.tar.xz`, with a
companion `.sha256`.

## Building locally

Requires a Fedora container runtime with privileges (privileged is needed for
the chroot/`dnf --installroot` steps):

```bash
mkdir -p output && podman run --rm --privileged \
  -v "$(pwd):/build:ro" \
  -v "$(pwd)/output:/output" \
  -e OUTPUT_DIR=/output \
  fedora:44 bash /build/fedora/build.sh
```

`output/` must exist before the run — podman bind-mounts it into the container,
and the mount fails (`statfs ...: no such file or directory`) if the host
directory is missing, hence the leading `mkdir -p`. The image lands in
`output/fedora-44-<arch>.tar.xz` alongside its `.sha256`.

## CI

[`.github/workflows/build-fedora.yml`](.github/workflows/build-fedora.yml)
builds both `x86_64` (on `ubuntu-latest`) and `aarch64` (on
`ubuntu-24.04-arm`) via the same `podman` invocation.

Triggers:

- **Push** to `main` touching `fedora/**` or the workflow — builds artifacts
  only (no release).
- **Monthly schedule** (15th, 03:17 UTC) — rebuilds for security updates and
  publishes a release tagged `fedora-44-<YYYYMMDD>`.
- **Manual dispatch** — optionally pass a `version` tag (e.g. `fedora-44-v2`)
  and publishes a release.

Releases attach both architecture tarballs and a combined `SHA256SUMS`.

## Using with incus-spawn

Point `incus-spawn`'s `minimal.yaml` at a release:

```yaml
image: fedora-44-base
image_url: https://github.com/Sanne/incus-spawn-images/releases/download/<tag>/fedora-44-{arch}.tar.xz
image_sha256:
  x86_64: <sha256>
  aarch64: <sha256>
```
