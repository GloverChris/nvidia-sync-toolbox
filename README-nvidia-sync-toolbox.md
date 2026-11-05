# NVIDIA Sync on Bluefin with Ubuntu Toolbx

This community setup runs NVIDIA Sync inside an Ubuntu 24.04 Toolbx while keeping the Bluefin host immutable. It creates a user-level app launcher and forwards dashboard links from the container to the host's existing default browser.

> Review before running. Toolbx is an integrated development environment, **not a security sandbox**: it shares your home directory, display sockets, networking, SSH agent, D-Bus, devices, and portions of the host filesystem. See the [Toolbx container configuration documentation](https://containertoolbx.org/doc/).

## What the script does

1. Creates or safely reuses an Ubuntu 24.04 amd64 Toolbx.
2. Installs NVIDIA Sync from NVIDIA's stable APT repository.
3. Installs the ALSA runtime library needed by the current Electron binary.
4. Adds a container-local `xdg-open` bridge that asks Bluefin to open URLs with its current default browser.
5. Adds `~/.local/share/applications/nvidia-sync-toolbox.desktop` so NVIDIA Sync appears in the app menu and can be pinned to the dock.

It does **not** change the host browser or MIME defaults, authenticate Tailscale, modify SSH credentials, expose dashboard ports, delete app data, or run the Toolbx as privileged.

## Prerequisites

- Bluefin, Fedora Silverblue, or a similar desktop with `toolbox` and rootless Podman.
- A graphical user session with a working host `/usr/bin/xdg-open`.
- Internet access for Ubuntu and NVIDIA's APT repositories.
- x86-64/amd64. NVIDIA's current repository package used by this workflow is amd64.
- Review NVIDIA's terms before installing. NVIDIA's official Ubuntu instructions are in [NVIDIA Sync: Getting Started](https://docs.nvidia.com/sync/latest/getting-started.html).

## Install

```bash
chmod +x setup-nvidia-sync-toolbox.sh
./setup-nvidia-sync-toolbox.sh --accept-nvidia-license
```

Defaults:

- Container: `nvidia-sync`
- Image: `quay.io/toolbx/ubuntu-toolbox:24.04`

Choose another safe container name or image when needed:

```bash
./setup-nvidia-sync-toolbox.sh \
  --container nvidia-sync-community \
  --image quay.io/toolbx/ubuntu-toolbox:24.04 \
  --accept-nvidia-license
```

The script refuses to reuse a same-named non-Toolbx container, a non-Ubuntu-24.04 container, or unrelated files at its managed paths. It never silently overwrites those collisions.

To explicitly test browser handoff after installation, add `--test-browser`. This opens NVIDIA's Getting Started page in the host browser; normal installation does not open a browser automatically.

## Check an existing setup

`--check` does not modify the persistent setup. It does not create/start a stopped container, download anything, install packages, rewrite setup files, or launch a browser.

```bash
./setup-nvidia-sync-toolbox.sh --container nvidia-sync --check
```

If an existing setup uses a different name, pass that name. A compatible older launcher or browser bridge is accepted and preserved even if it lacks this script's ownership marker.

## Why these extra compatibility steps exist

### NVIDIA installation

NVIDIA's supported Ubuntu flow configures `https://workbench.download.nvidia.com/stable/linux/debian`, updates APT, and installs `nvidia-sync`. The script uses the same official repository and package but stores a fresh setup in dedicated `signed-by` source/keyring files instead of appending repeatedly to global APT files. If a working NVIDIA repository configuration already exists, the script leaves it untouched and reuses it. See [NVIDIA Sync: Getting Started](https://docs.nvidia.com/sync/latest/getting-started.html) and NVIDIA's [DGX Spark connection guide](https://build.nvidia.com/spark/connect-to-your-spark/sync).

### Missing ALSA runtime

On the tested Ubuntu 24.04 Toolbx, `nvidia-sync 0.148.0~153-5805` required `libasound.so.2`, but that library was not declared in the package's dependency list. Installing `libasound2t64` fixed startup. The script selects `libasound2t64` when available and falls back to `libasound2` for compatibility. This is a tested Toolbx workaround, not an NVIDIA-documented installation step, and may become unnecessary in a future package.

### Host browser handoff

NVIDIA Sync opens DGX Dashboard URLs on loopback after establishing its SSH tunnel. Inside an Ubuntu Toolbx, the host's Flatpak browser desktop entry may point to `/usr/bin/flatpak`, which is not present in the container. The script installs only this container-local bridge:

```sh
exec /usr/bin/flatpak-spawn --host /usr/bin/xdg-open "$@"
```

Argument boundaries are preserved. The host still decides which browser to use. No MIME association or browser preference is changed, and no listener is rebound from `127.0.0.1`/`::1` to a public interface. NVIDIA describes Sync as managing SSH connections, forwarding, and tunnels in the [DGX Spark NVIDIA Sync guide](https://docs.nvidia.com/dgx/dgx-spark/nvidia-sync.html).

The wrapper is scoped to the named Toolbx, not solely to NVIDIA Sync: any process in that container that invokes `xdg-open` will hand the request to the host.

## Files and changes

Host user account:

- `~/.local/share/applications/nvidia-sync-toolbox.desktop`

Named Toolbx only:

- `/usr/local/bin/xdg-open`
- `nvidia-sync`, `flatpak-xdg-utils`, and an ALSA runtime package
- For a fresh repository setup only:
  - `/etc/apt/sources.list.d/nvidia-sync-toolbox.list`
  - `/etc/apt/keyrings/nvidia-sync-toolbox.gpg`

NVIDIA Sync keeps its application state under the shared home directory. This script neither reads nor removes that state.

## Rollback

Remove only files carrying this script's ownership markers:

```bash
./setup-nvidia-sync-toolbox.sh \
  --container nvidia-sync \
  --rollback-managed-files
```

Rollback intentionally preserves the package, repository, container, and NVIDIA Sync application data. A compatible file that predated the script and lacks its marker is also preserved.

Removing the entire Toolbx is a separate destructive choice. Inspect it first with `toolbox list`; if it was created only for NVIDIA Sync and contains nothing you need, stop NVIDIA Sync and remove the exact named container with:

```bash
podman stop nvidia-sync
toolbox rm nvidia-sync
```

Do not delete `~/.config/NVIDIA/Sync` unless you explicitly intend to erase NVIDIA Sync state and device configuration.

## Verification status

Verified on 2026-11-05 against a working Bluefin host and an Ubuntu 24.04 amd64 Toolbx:

- Existing-container detection and validation.
- Installed package `nvidia-sync 0.148.0~153-5805` from NVIDIA's stable repository.
- The missing ALSA requirement via `ldd`, with `libasound2t64` providing `libasound.so.2`.
- Desktop entry validation and launch through Toolbx.
- Host browser forwarding with DGX dashboard tunnels remaining loopback-only and returning HTTP 200.
- Shell syntax and invalid-name rejection.
- Two consecutive read-only `--check` runs, with launcher and bridge hashes and timestamps unchanged.

Not exercised here, to avoid changing the known-good machine:

- Creating a brand-new Toolbx.
- A clean installation from an empty APT state.
- ARM or non-Bluefin hosts.
- NVIDIA repository key rotation and future package versions.

Toolbx officially supports creating containers for another distribution/release, including Ubuntu, as documented in [Toolbx distro support](https://containertoolbx.org/distros/). NVIDIA's current Sync overview and platform guidance are in the [NVIDIA Sync User Guide](https://docs.nvidia.com/sync/latest/).

Rerunning install mode refreshes APT metadata and can upgrade NVIDIA Sync to the current version in NVIDIA's stable repository.
