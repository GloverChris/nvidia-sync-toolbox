#!/usr/bin/env bash

# Install NVIDIA Sync in an Ubuntu 24.04 Toolbx on an immutable Fedora/Bluefin
# host, add a user-scoped desktop launcher, and forward browser opens from the
# container to the host. See README-nvidia-sync-toolbox.md before running.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="1.0.0"
readonly DEFAULT_CONTAINER="nvidia-sync"
readonly DEFAULT_IMAGE="quay.io/toolbx/ubuntu-toolbox:24.04"
readonly NVIDIA_DOC_URL="https://docs.nvidia.com/sync/latest/getting-started.html"
readonly BRIDGE_PATH="/usr/local/bin/xdg-open"

container_name="$DEFAULT_CONTAINER"
container_image="$DEFAULT_IMAGE"
mode="install"
mode_selected=0
enable_browser_bridge=1
test_browser=0
license_accepted=0
work_dir=""
toolbox_bin=""
launcher_path=""
expected_bridge=""
expected_launcher=""

log() {
    printf '[nvidia-sync-toolbox] %s\n' "$*"
}

warn() {
    printf '[nvidia-sync-toolbox] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[nvidia-sync-toolbox] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: setup-nvidia-sync-toolbox.sh [options]

Install options:
  --container NAME             Toolbx name (default: nvidia-sync)
  --image IMAGE                Ubuntu Toolbx image
                               (default: quay.io/toolbx/ubuntu-toolbox:24.04)
  --accept-nvidia-license      Confirm you reviewed NVIDIA's license terms
  --no-browser-bridge          Do not install the host-browser handoff
  --test-browser               Explicitly open NVIDIA's Getting Started page
                               through the installed host-browser handoff

Read-only / rollback modes:
  --check                      Check an existing setup; make no persistent changes
  --rollback-managed-files     Remove only marker-owned launcher/bridge files

Other:
  -h, --help                   Show this help
  --version                    Show script version

This script never deletes a container, removes NVIDIA Sync data, changes the
host default browser, or exposes dashboard ports beyond loopback.
EOF
}

need_value() {
    local option="$1"
    local value="${2-}"
    [[ -n "$value" ]] || die "$option requires a value"
}

while (($#)); do
    case "$1" in
        --container)
            need_value "$1" "${2-}"
            container_name="$2"
            shift 2
            ;;
        --image)
            need_value "$1" "${2-}"
            container_image="$2"
            shift 2
            ;;
        --accept-nvidia-license)
            license_accepted=1
            shift
            ;;
        --no-browser-bridge)
            enable_browser_bridge=0
            shift
            ;;
        --test-browser)
            test_browser=1
            shift
            ;;
        --check)
            [[ "$mode_selected" -eq 0 ]] || die "choose only one of --check or --rollback-managed-files"
            mode="check"
            mode_selected=1
            shift
            ;;
        --rollback-managed-files)
            [[ "$mode_selected" -eq 0 ]] || die "choose only one of --check or --rollback-managed-files"
            mode="rollback"
            mode_selected=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --version)
            printf '%s\n' "$SCRIPT_VERSION"
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

[[ "$container_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || \
    die "invalid container name; use only letters, digits, dot, underscore, and hyphen"
[[ -n "$container_image" && "$container_image" != *$'\n'* ]] || die "invalid container image"
[[ "$EUID" -ne 0 ]] || die "run this script as your normal desktop user, not root"

if [[ "$mode" != "install" && "$test_browser" -eq 1 ]]; then
    die "--test-browser is available only during install mode"
fi
if [[ "$test_browser" -eq 1 && "$enable_browser_bridge" -eq 0 ]]; then
    die "--test-browser cannot be used with --no-browser-bridge"
fi

for command_name in toolbox podman cmp grep install mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || die "required host command not found: $command_name"
done

toolbox_bin="$(command -v toolbox)"
[[ "$toolbox_bin" == /* && "$toolbox_bin" != *[[:space:]]* ]] || \
    die "Toolbx must resolve to an absolute path without whitespace"

readonly data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
readonly launcher_dir="$data_home/applications"
launcher_path="$launcher_dir/nvidia-sync-toolbox.desktop"

cleanup() {
    if [[ -n "$work_dir" && -d "$work_dir" ]]; then
        rm -f -- "$work_dir/xdg-open" "$work_dir/nvidia-sync-toolbox.desktop"
        rmdir -- "$work_dir" 2>/dev/null || true
    fi
}
trap cleanup EXIT

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/nvidia-sync-toolbox.XXXXXX")"
expected_bridge="$work_dir/xdg-open"
expected_launcher="$work_dir/nvidia-sync-toolbox.desktop"

cat >"$expected_bridge" <<'EOF'
#!/bin/sh
# Managed-by: nvidia-sync-toolbox-setup
# Forward URL/file opening from this Toolbx to the host's default application.
exec /usr/bin/flatpak-spawn --host /usr/bin/xdg-open "$@"
EOF
chmod 0755 "$expected_bridge"

cat >"$expected_launcher" <<EOF
[Desktop Entry]
Type=Application
Name=NVIDIA Sync
Comment=NVIDIA Sync running in an Ubuntu Toolbx
TryExec=$toolbox_bin
Exec=$toolbox_bin run --container $container_name -- nvidia-sync
Icon=computer
Terminal=false
Categories=Network;
X-NvidiaSync-Toolbox-Managed=true
X-NvidiaSync-Toolbox-Container=$container_name
EOF
chmod 0644 "$expected_launcher"

if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$expected_launcher"
else
    warn "desktop-file-validate is unavailable; skipping optional launcher validation"
fi

container_exists() {
    podman container exists "$container_name"
}

container_running() {
    [[ "$(podman inspect --format '{{.State.Running}}' "$container_name" 2>/dev/null || true)" == "true" ]]
}

container_root() {
    podman exec --user 0 "$container_name" "$@"
}

validate_container() {
    local label os_release

    label="$(podman inspect --format '{{ index .Config.Labels "com.github.containers.toolbox" }}' "$container_name")"
    [[ "$label" == "true" ]] || die "container '$container_name' exists but is not a Toolbx container"

    if ! container_running; then
        if [[ "$mode" == "check" ]]; then
            die "container '$container_name' is stopped; --check will not start it"
        fi
        log "Starting existing Toolbx '$container_name'"
        toolbox run --container "$container_name" -- true
    fi

    os_release="$(toolbox run --container "$container_name" -- /bin/sh -c '. /etc/os-release; printf "%s|%s" "$ID" "$VERSION_ID"')"
    [[ "$os_release" == "ubuntu|24.04" ]] || \
        die "container '$container_name' is '$os_release'; Ubuntu 24.04 is required"

    [[ "$(toolbox run --container "$container_name" -- dpkg --print-architecture)" == "amd64" ]] || \
        die "NVIDIA's current Sync repository package is supported here only on amd64"
}

ensure_container() {
    if container_exists; then
        log "Reusing existing Toolbx '$container_name'"
    else
        [[ "$mode" == "install" ]] || die "Toolbx '$container_name' does not exist"
        log "Creating Toolbx '$container_name' from '$container_image'"
        toolbox create --image "$container_image" "$container_name"
    fi
    validate_container
}

confirm_license() {
    [[ "$license_accepted" -eq 1 ]] && return 0

    printf '\nInstalling NVIDIA Sync means downloading proprietary NVIDIA software.\n'
    printf 'Review NVIDIA\047s terms and installation notes at:\n  %s\n\n' "$NVIDIA_DOC_URL"
    if [[ -t 0 ]]; then
        local reply
        read -r -p "Continue with the NVIDIA installation? [y/N] " reply
        [[ "$reply" =~ ^[Yy]$ ]] || die "installation cancelled"
    else
        die "non-interactive install requires --accept-nvidia-license"
    fi
}

install_container_packages() {
    log "Configuring NVIDIA's stable APT repository and installing NVIDIA Sync"
    podman exec --interactive --user 0 "$container_name" /bin/bash -s <<'CONTAINER_ROOT'
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
readonly repo_url="https://workbench.download.nvidia.com/stable/linux/debian"
readonly key_url="https://workbench.download.nvidia.com/stable/linux/gpgkey"
# Observed from NVIDIA's HTTPS key endpoint on 2026-11-05. Fail closed on
# rotation so a maintainer can verify the replacement before updating this.
readonly expected_fingerprint="52ECDF6597CFBD865BF4DB3CD63F8B21266DE3C"
readonly keyring="/etc/apt/keyrings/nvidia-sync-toolbox.gpg"
readonly source_file="/etc/apt/sources.list.d/nvidia-sync-toolbox.list"

apt-get update
apt-get install --yes --no-install-recommends ca-certificates curl gnupg flatpak-xdg-utils

if apt-cache policy nvidia-sync 2>/dev/null | grep -Fq "$repo_url"; then
    printf '[nvidia-sync-toolbox] Reusing an existing NVIDIA APT repository configuration\n'
else
    tmp_dir="$(mktemp -d /tmp/nvidia-sync-repo.XXXXXX)"
    cleanup_repo_tmp() {
        rm -f -- "$tmp_dir/key.asc" "$tmp_dir/key.gpg" "$tmp_dir/source.list"
        rmdir -- "$tmp_dir" 2>/dev/null || true
    }
    trap cleanup_repo_tmp EXIT

    curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 \
        "$key_url" --output "$tmp_dir/key.asc"

    actual_fingerprint="$(gpg --batch --show-keys --with-colons "$tmp_dir/key.asc" \
        | awk -F: '$1 == "fpr" { print toupper($10); exit }')"
    [[ "$actual_fingerprint" == "$expected_fingerprint" ]] || {
        printf '[nvidia-sync-toolbox] ERROR: NVIDIA repository key fingerprint changed; expected %s, got %s\n' \
            "$expected_fingerprint" "${actual_fingerprint:-none}" >&2
        exit 1
    }

    gpg --batch --yes --dearmor --output "$tmp_dir/key.gpg" "$tmp_dir/key.asc"
    printf '%s\n%s\n' \
        '# Managed by nvidia-sync-toolbox-setup' \
        "deb [signed-by=$keyring] $repo_url default proprietary" \
        >"$tmp_dir/source.list"

    if [[ -e "$keyring" ]] && ! cmp -s "$tmp_dir/key.gpg" "$keyring"; then
        printf '[nvidia-sync-toolbox] ERROR: refusing to overwrite conflicting %s\n' "$keyring" >&2
        exit 1
    fi
    if [[ -e "$source_file" ]] && ! cmp -s "$tmp_dir/source.list" "$source_file"; then
        printf '[nvidia-sync-toolbox] ERROR: refusing to overwrite conflicting %s\n' "$source_file" >&2
        exit 1
    fi

    install -d -m 0755 /etc/apt/keyrings /etc/apt/sources.list.d
    [[ -e "$keyring" ]] || install -m 0644 "$tmp_dir/key.gpg" "$keyring"
    [[ -e "$source_file" ]] || install -m 0644 "$tmp_dir/source.list" "$source_file"
    apt-get update

    apt-cache policy nvidia-sync | grep -Fq "$repo_url" || {
        printf '[nvidia-sync-toolbox] ERROR: NVIDIA repository did not provide nvidia-sync\n' >&2
        exit 1
    }
fi

if apt-cache show libasound2t64 >/dev/null 2>&1; then
    alsa_package="libasound2t64"
elif apt-cache show libasound2 >/dev/null 2>&1; then
    alsa_package="libasound2"
else
    printf '[nvidia-sync-toolbox] ERROR: no compatible ALSA runtime package was found\n' >&2
    exit 1
fi

apt-get install --yes "$alsa_package" nvidia-sync
command -v nvidia-sync >/dev/null

if ldd "/opt/NVIDIA Sync/nvidia-sync.bin" | grep -q 'not found'; then
    printf '[nvidia-sync-toolbox] ERROR: NVIDIA Sync still has unresolved shared libraries\n' >&2
    ldd "/opt/NVIDIA Sync/nvidia-sync.bin" | grep 'not found' >&2 || true
    exit 1
fi

dpkg-query -W nvidia-sync "$alsa_package"
CONTAINER_ROOT
}

bridge_compatible() {
    podman exec "$container_name" /bin/sh -c \
        'test -f "$1" && test ! -L "$1" && test -x "$1" && grep -Fqx '\''exec /usr/bin/flatpak-spawn --host /usr/bin/xdg-open "$@"'\'' "$1"' \
        sh "$BRIDGE_PATH" && \
        [[ "$(toolbox run --container "$container_name" -- /bin/sh -c 'command -v xdg-open')" == "$BRIDGE_PATH" ]]
}

install_browser_bridge() {
    [[ "$enable_browser_bridge" -eq 1 ]] || {
        log "Skipping the optional host-browser bridge"
        return 0
    }

    toolbox run --container "$container_name" -- test -x /usr/bin/flatpak-spawn || \
        die "flatpak-spawn is unavailable inside '$container_name'"
    toolbox run --container "$container_name" -- /usr/bin/flatpak-spawn --host /usr/bin/test -x /usr/bin/xdg-open || \
        die "the Bluefin host does not provide /usr/bin/xdg-open"

    if podman exec "$container_name" test -e "$BRIDGE_PATH"; then
        if bridge_compatible; then
            log "Preserving the compatible existing browser bridge at $BRIDGE_PATH"
            return 0
        fi
        die "refusing to overwrite unrelated container file: $BRIDGE_PATH"
    fi

    local staged_path="/tmp/nvidia-sync-toolbox-xdg-open.$$"
    podman cp "$expected_bridge" "$container_name:$staged_path"
    if ! container_root /usr/bin/install -o root -g root -m 0755 "$staged_path" "$BRIDGE_PATH"; then
        container_root rm -f -- "$staged_path" || true
        die "failed to install the container browser bridge"
    fi
    container_root rm -f -- "$staged_path"

    [[ "$(toolbox run --container "$container_name" -- /bin/sh -c 'command -v xdg-open')" == "$BRIDGE_PATH" ]] || \
        die "the new browser bridge is not first in the container PATH"
    toolbox run --container "$container_name" -- /usr/bin/flatpak-spawn --host /usr/bin/true
    log "Installed the container-only host-browser bridge"
}

launcher_compatible() {
    [[ -f "$launcher_path" && ! -L "$launcher_path" ]] || return 1
    grep -Fqx "Exec=$toolbox_bin run --container $container_name -- nvidia-sync" "$launcher_path" || \
        grep -Fqx "Exec=/usr/bin/toolbox run --container $container_name -- nvidia-sync" "$launcher_path" || \
        grep -Fqx "Exec=toolbox run --container $container_name -- nvidia-sync" "$launcher_path"
}

install_launcher() {
    install -d -m 0755 "$launcher_dir"

    if [[ -e "$launcher_path" || -L "$launcher_path" ]]; then
        if [[ -f "$launcher_path" && ! -L "$launcher_path" ]] && cmp -s "$expected_launcher" "$launcher_path"; then
            log "Desktop launcher is already current"
            return 0
        fi
        if launcher_compatible; then
            warn "preserving a compatible existing launcher without changing its contents"
            return 0
        fi
        die "refusing to overwrite unrelated launcher: $launcher_path"
    fi

    install -m 0644 "$expected_launcher" "$launcher_path"
    log "Installed user launcher: $launcher_path"
}

check_setup() {
    local failed=0 installed_version=""

    if ! container_exists; then
        warn "Toolbx '$container_name' is missing"
        return 1
    fi
    validate_container

    installed_version="$(toolbox run --container "$container_name" -- dpkg-query -W -f='${Version}' nvidia-sync 2>/dev/null || true)"
    if [[ -n "$installed_version" ]]; then
        log "NVIDIA Sync package: $installed_version"
    else
        warn "nvidia-sync is not installed"
        failed=1
    fi

    if ! toolbox run --container "$container_name" -- /bin/sh -c \
        'ldd "/opt/NVIDIA Sync/nvidia-sync.bin" 2>/dev/null | grep -q "libasound.so.2 =>"'; then
        warn "ALSA runtime library is missing"
        failed=1
    fi

    if [[ "$enable_browser_bridge" -eq 1 ]]; then
        if bridge_compatible && \
            toolbox run --container "$container_name" -- /usr/bin/flatpak-spawn --host /usr/bin/true; then
            log "Host-browser bridge: ready"
        else
            warn "host-browser bridge is missing or incompatible"
            failed=1
        fi
    fi

    if launcher_compatible; then
        if command -v desktop-file-validate >/dev/null 2>&1; then
            desktop-file-validate "$launcher_path" || failed=1
        fi
        log "Desktop launcher: $launcher_path"
    else
        warn "compatible desktop launcher is missing at $launcher_path"
        failed=1
    fi

    if [[ "$failed" -eq 0 ]]; then
        log "Check passed; the setup is ready"
    else
        warn "Check completed with one or more problems"
    fi
    return "$failed"
}

rollback_managed_files() {
    local removed=0

    if [[ -f "$launcher_path" && ! -L "$launcher_path" ]] && \
        grep -Fqx 'X-NvidiaSync-Toolbox-Managed=true' "$launcher_path" && \
        grep -Fqx "X-NvidiaSync-Toolbox-Container=$container_name" "$launcher_path"; then
        rm -f -- "$launcher_path"
        log "Removed managed launcher: $launcher_path"
        removed=1
    elif [[ -e "$launcher_path" || -L "$launcher_path" ]]; then
        warn "leaving unmarked or mismatched launcher untouched: $launcher_path"
    fi

    if container_exists; then
        if ! container_running; then
            warn "container is stopped; leaving its browser bridge untouched"
        elif podman exec "$container_name" /bin/sh -c \
            'test -f "$1" && test ! -L "$1" && grep -Fqx "# Managed-by: nvidia-sync-toolbox-setup" "$1"' \
            sh "$BRIDGE_PATH"; then
            container_root rm -f -- "$BRIDGE_PATH"
            log "Removed managed container browser bridge: $BRIDGE_PATH"
            removed=1
        elif podman exec "$container_name" test -e "$BRIDGE_PATH"; then
            warn "leaving unmarked container browser bridge untouched: $BRIDGE_PATH"
        fi
    fi

    [[ "$removed" -eq 1 ]] || log "No marker-owned files were removed"
    warn "Packages, repository files, application data, and the Toolbx were intentionally preserved"
}

case "$mode" in
    check)
        check_setup
        ;;
    rollback)
        rollback_managed_files
        ;;
    install)
        confirm_license
        ensure_container
        install_container_packages
        install_browser_bridge
        install_launcher
        check_setup
        if [[ "$test_browser" -eq 1 ]]; then
            log "Opening NVIDIA's Getting Started page through the Bluefin host browser"
            toolbox run --container "$container_name" -- xdg-open "$NVIDIA_DOC_URL"
        fi
        log "Done. Launch NVIDIA Sync from the app menu and pin it to the dock if desired."
        ;;
esac
