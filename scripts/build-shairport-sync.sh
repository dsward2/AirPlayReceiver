#!/usr/bin/env bash
# Builds a self-contained shairport-sync (AirPlay 1 / RAOP) binary and vendors
# it, along with its non-system dylib dependencies, into
# Sources/AirPlayReceiver/Resources/. Regenerate this after bumping SS_VERSION
# or on a new build machine.
#
# Requires MacPorts (/opt/local) with: autoconf automake libtool pkgconfig
# popt libconfig-hr openssl3 soxr — install any missing ones with
# `sudo port install <name>`.
#
# Built WITHOUT --with-metadata/--with-ffmpeg/--with-airplay-2 (upstream's own
# configure.ac only pulls in ffmpeg for those), keeping the dependency tree to
# just popt/libconfig/openssl/soxr plus system frameworks (dns_sd is part of
# macOS itself). arm64-only for now; add an x86_64 MacPorts prefix + lipo step
# here if Intel Mac support is ever needed.
set -euo pipefail

SS_VERSION="5.1"
SS_SHA256="d85b5ad26449f3777518c4bfafeff0e4a6ebfb8333187df0ef462c199a4aba83"
SS_URL="https://github.com/mikebrady/shairport-sync/archive/refs/tags/${SS_VERSION}.tar.gz"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESOURCES_DIR="${PKG_ROOT}/Sources/AirPlayReceiver/Resources"
FRAMEWORKS_DIR="${RESOURCES_DIR}/Frameworks"
BUILD_DIR="$(mktemp -d /tmp/build-shairport-sync.XXXXXX)"
trap 'rm -rf "${BUILD_DIR}"' EXIT

MACPORTS_PREFIX="/opt/local"
export PATH="${MACPORTS_PREFIX}/bin:${MACPORTS_PREFIX}/sbin:${PATH}"
export PKG_CONFIG_PATH="${MACPORTS_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

echo "==> Downloading shairport-sync ${SS_VERSION}"
TARBALL="${BUILD_DIR}/shairport-sync.tar.gz"
curl -fsSL -o "${TARBALL}" "${SS_URL}"
ACTUAL_SHA256="$(shasum -a 256 "${TARBALL}" | awk '{print $1}')"
if [[ "${ACTUAL_SHA256}" != "${SS_SHA256}" ]]; then
    echo "error: checksum mismatch for shairport-sync ${SS_VERSION}" >&2
    echo "  expected: ${SS_SHA256}" >&2
    echo "  actual:   ${ACTUAL_SHA256}" >&2
    exit 1
fi
tar xzf "${TARBALL}" -C "${BUILD_DIR}"
SRC_DIR="$(find "${BUILD_DIR}" -maxdepth 1 -type d -name 'shairport-sync-*')"

echo "==> autoreconf"
(cd "${SRC_DIR}" && autoreconf -fi)

echo "==> configure (AirPlay 1 only: no metadata/ffmpeg/airplay-2)"
(cd "${SRC_DIR}" && ./configure \
    --with-os=darwin \
    --with-ssl=openssl \
    --with-dns_sd \
    --with-stdout \
    --with-pipe \
    --with-soxr \
    --with-piddir="${BUILD_DIR}" \
    --sysconfdir="${BUILD_DIR}/etc")

echo "==> make"
(cd "${SRC_DIR}" && make -j"$(sysctl -n hw.ncpu)")

BUILT_BINARY="${SRC_DIR}/shairport-sync"
[[ -x "${BUILT_BINARY}" ]] || { echo "error: build did not produce shairport-sync" >&2; exit 1; }

echo "==> Vendoring binary + dylib dependencies"
rm -rf "${RESOURCES_DIR}"
mkdir -p "${FRAMEWORKS_DIR}"
cp "${BUILT_BINARY}" "${RESOURCES_DIR}/shairport-sync"

# Recursively collect every /opt/local-provided dylib the binary (transitively)
# depends on, copy each one alongside, and rewrite install names/IDs to
# @executable_path/../Frameworks/<name> — the same convention AntennaHead
# already uses for its own vendored dylibs (see e.g. libFLAC.14.dylib,
# stereodemux in the AntennaHead repo root).
declare -A seen
queue=("${RESOURCES_DIR}/shairport-sync")
while [[ ${#queue[@]} -gt 0 ]]; do
    current="${queue[0]}"
    queue=("${queue[@]:1}")
    deps="$(otool -L "${current}" | tail -n +2 | awk '{print $1}' | grep -E "^${MACPORTS_PREFIX}/" || true)"
    while IFS= read -r dep; do
        [[ -z "${dep}" ]] && continue
        depname="$(basename "${dep}")"
        newpath="@executable_path/../Frameworks/${depname}"
        install_name_tool -change "${dep}" "${newpath}" "${current}"
        if [[ -z "${seen[${depname}]:-}" ]]; then
            seen[${depname}]=1
            cp "${dep}" "${FRAMEWORKS_DIR}/${depname}"
            chmod u+w "${FRAMEWORKS_DIR}/${depname}"
            install_name_tool -id "${newpath}" "${FRAMEWORKS_DIR}/${depname}"
            queue+=("${FRAMEWORKS_DIR}/${depname}")
        fi
    done <<< "${deps}"
done

echo "==> Codesigning (ad-hoc)"
for f in "${FRAMEWORKS_DIR}"/*; do
    codesign --force --sign - "${f}"
done
codesign --force --sign - "${RESOURCES_DIR}/shairport-sync"

echo "==> Done. Vendored files:"
find "${RESOURCES_DIR}" -type f | sed "s#${RESOURCES_DIR}/##"
echo
echo "Remember to 'git add' the Resources/ directory and commit."
