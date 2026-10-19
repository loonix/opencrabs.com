#!/usr/bin/env bash
# OpenCrabs installer.
#
#   curl -fsSL https://opencrabs.com/install.sh | bash
#
# Resolves the latest release, checks the platform, verifies the SHA-256 from
# the release's own SHA256SUMS file, and installs `opencrabs` (plus the `rtk`
# helper shipped in the same archive) into a directory on your PATH.
#
# Flags go after `bash -s --` when you pipe:
#   curl -fsSL https://opencrabs.com/install.sh | bash -s -- --version v0.5.11
#
#   --version <tag>   Install a specific release (default: the latest)
#   --dir <path>      Install directory (default: /usr/local/bin when writable,
#                     otherwise ~/.local/bin)
#   --dry-run         Print the plan and exit without downloading anything
#   -h, --help        Show this help

set -euo pipefail

REPO="opencrabs/opencrabs"
BIN="opencrabs"
RTK="rtk"
VERSION=""
INSTALL_DIR=""
DRY_RUN=0
GLIBC_MIN="2.38"

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
OpenCrabs installer.

  curl -fsSL https://opencrabs.com/install.sh | bash

Resolves the latest release, checks the platform, verifies the SHA-256 from the
release's own SHA256SUMS file, and installs `opencrabs` (plus the `rtk` helper
shipped in the same archive) into a directory on your PATH.

Flags go after `bash -s --` when you pipe:
  curl -fsSL https://opencrabs.com/install.sh | bash -s -- --version v0.5.11

  --version <tag>   Install a specific release (default: the latest)
  --dir <path>      Install directory (default: /usr/local/bin when writable,
                    otherwise ~/.local/bin)
  --dry-run         Print the plan and exit without downloading anything
  -h, --help        Show this help
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            [ $# -ge 2 ] || die "--version needs a value"
            VERSION="$2"
            shift 2
            ;;
        --version=*)
            VERSION="${1#*=}"
            shift
            ;;
        --dir)
            [ $# -ge 2 ] || die "--dir needs a value"
            INSTALL_DIR="$2"
            shift 2
            ;;
        --dir=*)
            INSTALL_DIR="${1#*=}"
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            die "unknown option '$1' (try --help)"
            ;;
    esac
done

# ---------------------------------------------------------------- platform

case "$(uname -s)" in
    Linux) OS="linux" ;;
    Darwin) OS="macos" ;;
    MINGW*|MSYS*|CYGWIN*)
        die "Windows: run  iwr -useb https://opencrabs.com/install.ps1 | iex"
        ;;
    *)
        die "unsupported operating system: $(uname -s)"
        ;;
esac

case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) die "unsupported architecture: $(uname -m) (releases ship amd64 and arm64)" ;;
esac

# Compare dotted versions: exits 0 when $1 < $2.
ver_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        n = split(a, x, ".");
        split(b, y, ".");
        for (i = 1; i <= 3; i++) {
            if ((x[i] + 0) < (y[i] + 0)) exit 0;
            if ((x[i] + 0) > (y[i] + 0)) exit 1;
        }
        exit 1;
    }'
}

# The release binaries are linked against glibc, so a musl distro or an older
# glibc fails at exec time with a confusing loader error. Catch it here.
check_glibc() {
    local have
    if ! command -v ldd >/dev/null 2>&1; then
        warn "ldd not found, cannot check the glibc version"
        return
    fi
    if ldd --version 2>&1 | grep -qi musl; then
        die "this build needs glibc ${GLIBC_MIN}+ and this system uses musl (Alpine?). Build from source instead: https://docs.opencrabs.com/development/building"
    fi
    have="$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$' | tail -1)"
    [ -n "$have" ] || { warn "could not read the glibc version"; return; }
    if ver_lt "$have" "$GLIBC_MIN"; then
        die "glibc ${have} is too old, this build needs ${GLIBC_MIN}+ (Ubuntu 24.04+, Debian 13+, Fedora 39+). Use Homebrew, cargo, or build from source."
    fi
}

# Run a command as root, without ever hanging on a password prompt: a piped
# installer has no terminal to ask on.
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo "$@"
    else
        return 1
    fi
}

# libgomp.so.1 is a hard NEEDED entry of the Linux build (llama-cpp-2), and
# libssl.so.3 comes with the OpenSSL runtime. Neither is guaranteed present.
ensure_linux_libs() {
    local missing="" pkg_hint=""
    ldconfig -p 2>/dev/null | grep -q 'libgomp\.so\.1' || missing="libgomp"
    ldconfig -p 2>/dev/null | grep -q 'libssl\.so\.3' || missing="${missing:+$missing }libssl"

    [ -n "$missing" ] || return 0

    if command -v apt-get >/dev/null 2>&1; then
        pkg_hint="sudo apt-get update && sudo apt-get install -y libgomp1 libssl3"
        as_root apt-get update -qq && as_root apt-get install -y -qq libgomp1 libssl3 || true
    elif command -v dnf >/dev/null 2>&1; then
        pkg_hint="sudo dnf install -y libgomp openssl-libs"
        as_root dnf install -y libgomp openssl-libs || true
    elif command -v zypper >/dev/null 2>&1; then
        pkg_hint="sudo zypper install -y libgomp1 libopenssl3"
        as_root zypper --non-interactive install libgomp1 libopenssl3 || true
    elif command -v pacman >/dev/null 2>&1; then
        pkg_hint="sudo pacman -S --needed gcc-libs openssl"
        as_root pacman -S --needed --noconfirm gcc-libs openssl || true
    fi

    if ldconfig -p 2>/dev/null | grep -q 'libgomp\.so\.1'; then
        say "Installed the missing system libraries."
    else
        warn "missing $missing. OpenCrabs will fail to start until you install it:"
        warn "  ${pkg_hint:-install libgomp and libssl with your package manager}"
    fi
}

# ---------------------------------------------------------------- release

resolve_version() {
    local url tag
    [ -n "$VERSION" ] && return 0

    # The /releases/latest redirect already carries the tag, and unlike the API
    # it is not rate limited per IP (a shared NAT runs out of API calls fast).
    url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest" 2>/dev/null || true)"
    tag="${url##*/}"
    case "$tag" in
        v[0-9]*) VERSION="$tag"; return 0 ;;
    esac

    VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -1)"
    [ -n "$VERSION" ] || die "could not resolve the latest release (github.com may be unreachable)"
}

# ---------------------------------------------------------------- main

command -v curl >/dev/null 2>&1 || die "curl is required"

[ "$OS" = "linux" ] && check_glibc
resolve_version

ASSET="${BIN}-${VERSION}-${OS}-${ARCH}.tar.gz"
BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"

if [ -z "$INSTALL_DIR" ]; then
    if [ -w /usr/local/bin ] 2>/dev/null; then
        INSTALL_DIR="/usr/local/bin"
    else
        INSTALL_DIR="${HOME}/.local/bin"
    fi
fi

say "OpenCrabs ${VERSION} (${OS}/${ARCH})"
say "  install to  ${INSTALL_DIR}"
say "  archive     ${ASSET}"

if [ "$DRY_RUN" -eq 1 ]; then
    say "dry run: nothing downloaded, nothing installed"
    exit 0
fi

[ "$OS" = "linux" ] && ensure_linux_libs

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opencrabs-install.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

say "Downloading..."
curl -fsSL --retry 3 --retry-delay 1 -o "${TMP_DIR}/${ASSET}" "${BASE_URL}/${ASSET}" \
    || die "download failed: ${BASE_URL}/${ASSET}"
curl -fsSL --retry 3 --retry-delay 1 -o "${TMP_DIR}/SHA256SUMS" "${BASE_URL}/SHA256SUMS" \
    || die "could not download SHA256SUMS, refusing to install unverified"

EXPECTED="$(awk -v a="$ASSET" '$2 == a { print $1; exit }' "${TMP_DIR}/SHA256SUMS")"
[ -n "$EXPECTED" ] || die "SHA256SUMS has no entry for ${ASSET}"

if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL="$(sha256sum "${TMP_DIR}/${ASSET}" | awk '{ print $1 }')"
elif command -v shasum >/dev/null 2>&1; then
    ACTUAL="$(shasum -a 256 "${TMP_DIR}/${ASSET}" | awk '{ print $1 }')"
else
    die "need sha256sum or shasum to verify the download"
fi

if [ "$ACTUAL" != "$EXPECTED" ]; then
    die "checksum mismatch for ${ASSET}
  expected ${EXPECTED}
  actual   ${ACTUAL}
Refusing to install. Re-run, or download it yourself from ${BASE_URL}"
fi
say "Checksum OK."

tar xzf "${TMP_DIR}/${ASSET}" -C "$TMP_DIR" || die "could not extract ${ASSET}"
[ -f "${TMP_DIR}/${BIN}" ] || die "${ASSET} does not contain a ${BIN} binary"

mkdir -p "$INSTALL_DIR"
install -m 0755 "${TMP_DIR}/${BIN}" "${INSTALL_DIR}/${BIN}"
if [ -f "${TMP_DIR}/${RTK}" ]; then
    install -m 0755 "${TMP_DIR}/${RTK}" "${INSTALL_DIR}/${RTK}"
fi

# curl does not set the quarantine flag, but a binary that was unzipped by
# another tool may carry it and Gatekeeper would block the first launch.
if [ "$OS" = "macos" ]; then
    xattr -d com.apple.quarantine "${INSTALL_DIR}/${BIN}" 2>/dev/null || true
fi

case ":${PATH}:" in
    *":${INSTALL_DIR}:"*) ;;
    *)
        warn "${INSTALL_DIR} is not on your PATH. Add it:"
        warn "  export PATH=\"${INSTALL_DIR}:\$PATH\""
        ;;
esac

say ""
say "OpenCrabs ${VERSION} installed at ${INSTALL_DIR}/${BIN}"
say "Run: ${BIN}"
say "It opens straight into the chat with the built-in provider already live,"
say "so you can start talking without a key or an account."
say "Setup wizard: ${BIN} --onboard"
