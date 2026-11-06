#!/usr/bin/env bash
# Safe unit tests: extract helpers only; package managers are shell mocks.
set -Eeuo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
helpers="$(sed -n '/^# Host dependency helpers/,/^# End host dependency helpers/p' "$repo_dir/setup-nvidia-sync-toolbox.sh")"

run_case() (
    set -Eeuo pipefail
    local scenario="$1"
    mode=install
    install_host_dependencies=0
    mock_platform=fedora
    have_toolbox=0
    have_podman=0
    install_succeeds=1
    called=0
    log() { :; }
    warn() { :; }
    die() { printf '%s\n' "$*" >&2; exit 23; }
    command() {
        if [[ "${1-}" == -v ]]; then
            case "$2" in
                toolbox) [[ "$have_toolbox" -eq 1 ]];;
                podman) [[ "$have_podman" -eq 1 ]];;
                dnf|sudo) return 0;;
                *) return 1;;
            esac
        else
            builtin command "$@"
        fi
    }
    sudo() {
        [[ "$*" == "$expected_command" ]] || { echo "wrong install command: $*" >&2; exit 99; }
        called=$((called + 1))
        [[ "$install_succeeds" -eq 1 ]] || return 1
        have_toolbox=1
        have_podman=1
    }
    eval "$helpers"
    host_install_platform() { printf '%s\n' "$mock_platform"; }
    expected_command='dnf install --yes toolbox podman'
    case "$scenario" in
        existing) have_toolbox=1; have_podman=1;;
        approved) install_host_dependencies=1;;
        only-toolbox) install_host_dependencies=1; have_podman=1; expected_command='dnf install --yes toolbox';;
        only-podman) install_host_dependencies=1; have_toolbox=1; expected_command='dnf install --yes podman';;
        no-consent) :;;
        check) mode=check; install_host_dependencies=1;;
        rollback) mode=rollback; install_host_dependencies=1;;
        immutable) mock_platform=immutable; install_host_dependencies=1;;
        unsupported) mock_platform=unknown; install_host_dependencies=1;;
        install-fails) install_host_dependencies=1; install_succeeds=0;;
    esac
    ensure_host_dependencies </dev/null
    case "$scenario" in
        existing) [[ "$called" -eq 0 ]];;
        approved|only-toolbox|only-podman)
            [[ "$called" -eq 1 ]]
            ensure_host_dependencies </dev/null
            [[ "$called" -eq 1 ]] # idempotent after install
            ;;
        *) echo "unexpected success: $scenario" >&2; exit 99;;
    esac
)

for scenario in existing approved only-toolbox only-podman; do
    run_case "$scenario"
    printf 'PASS %s\n' "$scenario"
done
for scenario in no-consent check rollback immutable unsupported install-fails; do
    set +e
    (run_case "$scenario") >/dev/null 2>&1
    status=$?
    set -e
    [[ "$status" -eq 23 ]] || { echo "FAIL $scenario (status $status)" >&2; exit 1; }
    printf 'PASS %s\n' "$scenario"
done
printf 'All host dependency tests passed; no real package manager was invoked.\n'
