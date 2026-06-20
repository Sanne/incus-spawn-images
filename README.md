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

After building locally (see above), you can test the image without publishing a
release. The easiest way is to define a standalone test template in
`~/.config/incus-spawn/images/` — this keeps your real `tpl-minimal` untouched:

```yaml
# ~/.config/incus-spawn/images/test-base.yaml
name: tpl-test-base
description: Local base image test
image: fedora-44-test
image_url: file:///path/to/incus-spawn-images/output/fedora-44-{arch}.tar.xz
image_tag: local-test
```

Then build it:

```bash
isx build tpl-test-base      # imports the local tarball
isx branch tpl-test-base     # launch an instance to verify
```

No `image_sha256` — omitting it skips the hash check, which is what you want
during iterative testing. The `image_tag` value triggers re-import when changed,
so bump it (e.g. `local-test-2`) each time you rebuild the tarball.

Alternatively, you can override `tpl-minimal` directly to test how derived
templates (`tpl-dev`, `tpl-java`, etc.) behave on the new base. Create
`~/.config/incus-spawn/images/minimal.yaml`:

```yaml
name: tpl-minimal
description: Base OS only
image: fedora-44-base
image_url: file:///path/to/incus-spawn-images/output/fedora-44-{arch}.tar.xz
image_tag: local-test
```

Then rebuild the full chain (`isx build tpl-minimal`, `isx build tpl-dev`, etc.).
When done, delete the override to revert to the released image:

```bash
rm ~/.config/incus-spawn/images/minimal.yaml
# or: rm ~/.config/incus-spawn/images/test-base.yaml
```

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
