#!/usr/bin/env bash
# ==============================================================================
# MailiaM Linux Release Build Script (GitHub CI Replacement)
# ==============================================================================
# Mirrors the Linux jobs from GitHub Actions (.github/workflows/ci.yml).
# Provides full offline / internet blackout compatibility with zero external
# dependencies when local assets and cargo cache/vendor are present.
#
# PREREQUISITES:
#   1. Frontend Assets:
#      - resources/webui.zip (already committed in repo)
#      - crates/deltachat/assets/ (already committed in repo)
#      - scripts/fetch-assets.sh automatically reuses local assets when offline.
#
#   2. Build Toolchains:
#      - Docker BuildKit (default multi-target cross-build):
#          * docker with buildx support (`docker buildx version`)
#          * Uses Dockerfile.build (cargo-zigbuild) — no QEMU required for Rust.
#      - Native host build (--native):
#          * rustc >= 1.85, cargo
#          * C build tools: make, gcc / clang
#
#   3. Air-gapped / Blackout Usage:
#      - Run `./scripts/build-release.sh --vendor` once while online to vendor
#        all Rust crates into `./vendor` and configure offline sources.
#      - Once vendored, `./scripts/build-release.sh --native --offline` builds
#        the full binary with ZERO network requests.
#
# TARGET MATRIX (Matches GitHub Actions ci.yml):
#   - x86_64-unknown-linux-musl       -> dist/mailiam-x86_64-linux.tar.gz
#   - aarch64-unknown-linux-musl      -> dist/mailiam-aarch64-linux.tar.gz
#   - armv7-unknown-linux-musleabihf  -> dist/mailiam-armv7-linux.tar.gz
#
# OUTPUT ARTIFACTS:
#   - artifacts/<target>/mailiam        (Raw uncompressed ELF binaries)
#   - dist/mailiam-<arch>-linux.tar.gz  (Release archives for install.sh)
#   - dist/SHA256SUMS                   (SHA-256 checksums matching CI)
# ==============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
ARTIFACTS_DIR="${ROOT_DIR}/artifacts"
CARGO_FEATURES="sqlite postgres mysql rocks s3 redis azure nats enterprise"

# Configuration defaults (Blackout by default: zero internet queries)
BUILD_MODE="native"       # Default: native offline build (no Docker, 0 network)
OFFLINE=1                 # Default: strictly offline (no network queries)
SPECIFIC_TARGET=""        # Empty = all matrix targets
BUILD_IMAGE=""            # Non-empty = tag to build with Dockerfile.image
VENDOR_DEPS=0             # 1 = vendor cargo dependencies for offline use

show_help() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Default mode is strictly OFFLINE native build for blackout compatibility.
No network requests will be made unless --online is explicitly specified.

Options:
  --native              Build natively for current host architecture using cargo (default).
  --offline             Strictly offline: do not touch network (default: active).
  --online              Allow network access to query latest upstream assets/crates.
  --docker              Build cross-compiled Linux binaries via Docker BuildKit.
  --target <TRIPLE>     Build only specific target (e.g. x86_64-unknown-linux-musl or host).
  --image [TAG]         Build local Docker runtime image using Dockerfile.image (e.g. mailiam:latest).
  --vendor              Vendor all Cargo dependencies into ./vendor for air-gapped systems.
  -h, --help            Show this help message.

Examples:
  # Blackout build (zero network, native cargo, instant):
  bash scripts/build-release.sh

  # Package resulting binary into Docker image:
  bash scripts/build-release.sh --image mailiam:latest

  # Prepare air-gapped source tree with all vendor crates:
  bash scripts/build-release.sh --online --vendor
EOF
}

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --native)
            BUILD_MODE="native"
            shift
            ;;
        --docker)
            BUILD_MODE="docker"
            shift
            ;;
        --offline)
            OFFLINE=1
            shift
            ;;
        --online)
            OFFLINE=0
            shift
            ;;
        --target)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --target requires an argument" >&2
                exit 1
            fi
            SPECIFIC_TARGET="$2"
            shift 2
            ;;
        --image)
            if [[ -n "${2:-}" && ! "$2" =~ ^-- ]]; then
                BUILD_IMAGE="$2"
                shift 2
            else
                BUILD_IMAGE="mailiam:latest"
                shift
            fi
            ;;
        --vendor)
            VENDOR_DEPS=1
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            show_help >&2
            exit 1
            ;;
    esac
done

cd "${ROOT_DIR}"
mkdir -p "${DIST_DIR}" "${ARTIFACTS_DIR}"

# Helper for portable sha256 calculation
compute_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@"
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$@"
    else
        openssl dgst -sha256 "$@"
    fi
}

# ------------------------------------------------------------------------------
# Vendor dependencies if requested
# ------------------------------------------------------------------------------
if [[ "$VENDOR_DEPS" -eq 1 ]]; then
    echo "==> Vendoring all cargo dependencies into ./vendor for air-gapped usage..."
    cargo vendor --versioned-dirs vendor
    mkdir -p .cargo
    cat > .cargo/config.toml << 'CARGO_CFG'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"
CARGO_CFG
    echo "==> Dependencies vendored and .cargo/config.toml configured."
    echo "    The repository can now be copied to an air-gapped machine."
    exit 0
fi

# ------------------------------------------------------------------------------
# Step 1: Ensure frontend assets are available (WebUI + DeltaChat Relay SPA)
# ------------------------------------------------------------------------------
echo "==> [1/4] Verifying embedded frontend assets..."
export OFFLINE
sh scripts/fetch-assets.sh

# ------------------------------------------------------------------------------
# Step 2: Build release binaries
# ------------------------------------------------------------------------------
echo "==> [2/4] Building binaries (mode: ${BUILD_MODE})..."

if [[ "${BUILD_MODE}" == "native" ]]; then
    # Native host build via cargo
    CARGO_FLAGS=(--release -p stalwart --no-default-features --features "${CARGO_FEATURES}")
    if [[ "$OFFLINE" -eq 1 ]]; then
        CARGO_FLAGS+=(--offline)
    fi

    HOST_ARCH="$(uname -m)"
    case "${HOST_ARCH}" in
        x86_64) SHORT_TARGET="x86_64-linux" ;;
        aarch64|arm64) SHORT_TARGET="aarch64-linux" ;;
        armv7*|armhf) SHORT_TARGET="armv7-linux" ;;
        *) SHORT_TARGET="${HOST_ARCH}-linux" ;;
    esac

    TARGET_DIR_NAME="native-${SHORT_TARGET}"
    OUT_DIR="${ARTIFACTS_DIR}/${TARGET_DIR_NAME}"
    mkdir -p "${OUT_DIR}"

    echo "==> Compiling native release binary with host cargo (${SHORT_TARGET})..."
    cargo build "${CARGO_FLAGS[@]}"

    cp "target/release/mailiam" "${OUT_DIR}/mailiam"
    chmod 0755 "${OUT_DIR}/mailiam"

    echo "==> [3/4] Packaging dist/mailiam-${SHORT_TARGET}.tar.gz..."
    tar -czf "${DIST_DIR}/mailiam-${SHORT_TARGET}.tar.gz" -C "${OUT_DIR}" mailiam

else
    # Multi-target cross-compilation via Docker BuildKit (matches GitHub CI)
    if ! command -v docker >/dev/null 2>&1; then
        echo "Error: Docker not found. Install docker or run with --native." >&2
        exit 1
    fi

    TARGETS=(
        "x86_64-unknown-linux-musl::x86_64-linux"
        "aarch64-unknown-linux-musl:JEMALLOC_SYS_WITH_LG_PAGE=16 :aarch64-linux"
        "armv7-unknown-linux-musleabihf:JEMALLOC_SYS_WITH_LG_PAGE=16 :armv7-linux"
    )

    for item in "${TARGETS[@]}"; do
        IFS=":" read -r target build_env short <<< "$item"

        if [[ -n "${SPECIFIC_TARGET}" && "${SPECIFIC_TARGET}" != "${target}" && "${SPECIFIC_TARGET}" != "${short}" ]]; then
            continue
        fi

        echo "----------------------------------------------------------------"
        echo "==> Building ${target} -> ${short}"
        echo "----------------------------------------------------------------"

        DEST_DIR="${ARTIFACTS_DIR}/${target}"
        mkdir -p "${DEST_DIR}"

        BUILD_ARGS=(
            --file Dockerfile.build
            --target binaries
            --build-arg TARGET="${target}"
            --output "type=local,dest=${DEST_DIR}"
        )

        if [[ -n "${build_env}" ]]; then
            BUILD_ARGS+=(--build-arg BUILD_ENV="${build_env}")
        fi

        docker buildx build "${BUILD_ARGS[@]}" .

        echo "==> Packaging dist/mailiam-${short}.tar.gz..."
        tar -czf "${DIST_DIR}/mailiam-${short}.tar.gz" -C "${DEST_DIR}" mailiam
    done
fi

# ------------------------------------------------------------------------------
# Step 3: Compute Checksums
# ------------------------------------------------------------------------------
echo "==> [3/4] Computing SHA-256 checksums..."
(
    cd "${DIST_DIR}"
    compute_sha256 mailiam-*.tar.gz > SHA256SUMS
)
cat "${DIST_DIR}/SHA256SUMS"

# ------------------------------------------------------------------------------
# Step 4: Optional Docker Image Packaging
# ------------------------------------------------------------------------------
if [[ -n "${BUILD_IMAGE}" ]]; then
    echo "==> [4/4] Building Docker runtime image (${BUILD_IMAGE})..."

    # Locate an available musl binary to package into the runtime image
    CANDIDATE_BIN=""
    if [[ -f "${ARTIFACTS_DIR}/x86_64-unknown-linux-musl/mailiam" ]]; then
        CANDIDATE_BIN="${ARTIFACTS_DIR}/x86_64-unknown-linux-musl"
    else
        # Find first artifact directory containing mailiam
        for d in "${ARTIFACTS_DIR}"/*; do
            if [[ -f "${d}/mailiam" ]]; then
                CANDIDATE_BIN="${d}"
                break
            fi
        done
    fi

    if [[ -z "${CANDIDATE_BIN}" ]]; then
        echo "Error: No compiled mailiam binary found to package into Docker image." >&2
        exit 1
    fi

    echo "==> Building image using binary from ${CANDIDATE_BIN}..."
    docker buildx build \
        --file Dockerfile.image \
        -t "${BUILD_IMAGE}" \
        --load \
        "${CANDIDATE_BIN}"

    echo "==> Docker image built successfully: ${BUILD_IMAGE}"
else
    echo "==> [4/4] Release build complete."
fi

echo ""
echo "================================================================"
echo "Artifacts generated in: ${DIST_DIR}"
ls -lh "${DIST_DIR}"
echo "================================================================"
