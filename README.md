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

`systemd-udev` is installed (as a systemd dependency and for `udevadm`). Its
services run but are mostly inert — in unprivileged containers, udevd can't
write to `/sys` or receive kernel netlink events since device nodes are
host-managed by Incus. We keep it running because `dhcpcd` uses a udev plugin
for interface detection. A `/etc/tmpfiles.d/static-nodes-permissions.conf`
override prevents `fchmod` failures on `/dev/net/tun` and `/dev/fuse` during
rpm `%triggerin` scriptlets (the host-injected device nodes can't have their
permissions changed inside the user namespace).

**Trimmed systemd units.** ~20 services/timers/sockets that are useless or
harmful in a container are masked — `systemd-homed` (+ firstboot), the
`systemd-pcrlock-*` and `systemd-tpm2-clear` TPM units, time sync
(`timesyncd`, `time-wait-sync`), `systemd-boot-*` and `systemd-sysupdate*`,
`systemd-firstboot`, `unbound-anchor.timer`, `fstrim.timer`, and
`selinux-autorelabel-mark`.

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

`output/` must exist before the run — hence the leading `mkdir -p`.
The image lands in `output/fedora-44-<arch>.tar.xz` alongside its `.sha256`.

## CI

[`.github/workflows/build-fedora.yml`](.github/workflows/build-fedora.yml)
builds both `x86_64` (on a regular instance) and `aarch64` (on an arm instance)
via the same `podman` invocation.

Triggers:

- **Push** to `main` touching `fedora/**` or the workflow — builds artifacts
  only (no release).
- **Monthly schedule** (15th, 03:17 UTC) — rebuilds for security updates and
  publishes a release tagged `fedora-44-<YYYYMMDD>`.
- **Manual dispatch** — optionally pass a `version` tag (e.g. `fedora-44-v2`)
  and publishes a release.

Releases attach both architecture tarballs and a combined `SHA256SUMS`.

## Testing locally with incus-spawn

The quickest way to build and test a local image:

```bash
./test-local.sh              # builds image, configures isx to use it
isx build tpl-minimal        # imports the local tarball
isx build tpl-dev             # rebuild derived templates
./revert-local.sh            # reverts isx to the built-in base image
```

`test-local.sh` runs the podman build, then writes a `tpl-minimal` override
pointing at the local tarball via a `file://` URL. Each run generates a unique
tag so `isx` re-imports automatically. `revert-local.sh` deletes the override.

### Manual setup

If you prefer to set things up by hand, or want a standalone test template that
doesn't override `tpl-minimal`, create a YAML file in
`~/.config/incus-spawn/images/`:

```yaml
# ~/.config/incus-spawn/images/test-base.yaml
name: tpl-test-base
description: Local base image test
image: fedora-44-test
image_url: file:///path/to/incus-spawn-images/output/fedora-44-{arch}.tar.xz
image_tag: local-test
```

No `image_sha256` — omitting it skips the hash check, which is what you want
during iterative testing. Bump `image_tag` each time you rebuild the tarball
so `isx` detects the change and re-imports.

To override `tpl-minimal` directly (so derived templates like `tpl-dev` build
on top of your local image), use `name: tpl-minimal` instead. When done, delete
the override to revert:

```bash
rm ~/.config/incus-spawn/images/minimal.yaml
# or: rm ~/.config/incus-spawn/images/test-base.yaml
```

## Releasing a new version

To publish a new base image release:

1. **Trigger the workflow** — either via the GitHub UI (Actions → Build Fedora
   Base Image → Run workflow) or the CLI:

   ```bash
   # Auto-generated date tag (fedora-44-YYYYMMDD):
   gh workflow run build-fedora.yml

   # Explicit tag:
   gh workflow run build-fedora.yml --field version=fedora-44-v7
   ```

2. **Wait for CI** — the workflow builds both `x86_64` and `aarch64` images and
   creates a GitHub release with the tarballs and `SHA256SUMS`.

3. **Update `incus-spawn`** — edit
   `src/main/resources/images/minimal.yaml` in the `incus-spawn` repo:

   ```yaml
   image_tag: fedora-44-YYYYMMDD          # the new release tag
   image_sha256:
     x86_64: <sha256-from-SHA256SUMS>
     aarch64: <sha256-from-SHA256SUMS>
   ```

   Get the checksums from the release's `SHA256SUMS` file:

   ```bash
   curl -sL https://github.com/Sanne/incus-spawn-images/releases/download/<tag>/SHA256SUMS
   ```

4. **Rebuild and test `isx`** — `mvn package && ./install.sh`, then
   `isx build tpl-minimal` to verify the new image imports and boots correctly.

Monthly scheduled builds (15th, 03:17 UTC) automatically create a release for
security updates. Pushes to `main` touching `fedora/**` build artifacts but
don't release — use manual dispatch to publish those changes.

## Using with incus-spawn

The built-in `tpl-minimal` template in `incus-spawn` already points at this
repository's releases. On each `isx build tpl-minimal`, the tool checks whether
the installed base image matches the expected tag and re-downloads if needed.

### Managing base image versions

`isx update-base` checks for new releases and lets you choose how to track them:

```bash
isx update-base              # interactive — list releases, choose track-latest or pin
isx update-base --latest     # always track the newest built-in version
isx update-base --list       # list available releases without changing anything
isx update-base fedora-44-v3 # pin to a specific release tag
```

**Track latest** (default): no user override is written — `isx` uses whatever
tag is baked into the current binary. Updating `isx` automatically picks up
newer base images.

**Pinned**: writes a user override to `~/.config/incus-spawn/images/minimal.yaml`
with `pinned: true`. The pinned version is used until you explicitly change it.
If a newer version becomes available in a later `isx` release, the build will
print a warning:

```
Warning: base image is pinned to fedora-44-v3, but fedora-44-20260619 is available.
Run 'isx update-base --latest' to update.
```

### Pointing at a release manually

To reference a specific release directly in a template definition:

```yaml
image: fedora-44-base
image_url: https://github.com/Sanne/incus-spawn-images/releases/download/<tag>/fedora-44-{arch}.tar.xz
image_sha256:
  x86_64: <sha256>
  aarch64: <sha256>
```
