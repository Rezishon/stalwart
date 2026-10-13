#!/bin/sh
# Pin-check webui.zip and signup-relay dist. Build machine only. Runtime never calls this.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
LOCK="$ROOT/resources/assets.lock"
WEBUI_ZIP="$ROOT/resources/webui.zip"
RELAY_DIR="$ROOT/crates/deltachat/assets"
RELAY_REV_FILE="$RELAY_DIR/RELAY_REV"

webui_url=
webui_sha256=
relay_repo=
relay_rev=

while IFS='=' read -r key value; do
    case "$key" in
        webui_url) webui_url=$value ;;
        webui_sha256) webui_sha256=$value ;;
        relay_repo) relay_repo=$value ;;
        relay_rev) relay_rev=$value ;;
    esac
done < "$LOCK"

if [ -z "$webui_url" ] || [ -z "$webui_sha256" ] || [ -z "$relay_repo" ] || [ -z "$relay_rev" ]; then
    echo "fetch-assets: incomplete $LOCK" >&2
    exit 1
fi

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

if [ -f "$WEBUI_ZIP" ] && [ "$(sha256_of "$WEBUI_ZIP")" = "$webui_sha256" ]; then
    echo "webui.zip ok ($webui_sha256)"
else
    tmp=$(mktemp)
    echo "downloading webui.zip"
    curl -fsSL --retry 5 -o "$tmp" "$webui_url"
    got=$(sha256_of "$tmp")
    if [ "$got" != "$webui_sha256" ]; then
        echo "fetch-assets: webui sha256 mismatch: got $got want $webui_sha256" >&2
        rm -f "$tmp"
        exit 1
    fi
    mv "$tmp" "$WEBUI_ZIP"
    echo "webui.zip updated"
fi

if [ -f "$RELAY_REV_FILE" ] && [ "$(cat "$RELAY_REV_FILE")" = "$relay_rev" ] \
    && [ -f "$RELAY_DIR/index.html" ]; then
    echo "relay assets ok ($relay_rev)"
    exit 0
fi

if ! command -v npm >/dev/null 2>&1; then
    echo "fetch-assets: npm required to build signup-relay (rev $relay_rev)" >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
echo "cloning signup-relay @$relay_rev"
git clone --filter=blob:none --no-checkout "$relay_repo" "$work/src"
git -C "$work/src" fetch --depth 1 origin "$relay_rev"
git -C "$work/src" checkout --force "$relay_rev"
(cd "$work/src/frontend" && npm ci && npm run build)
mkdir -p "$RELAY_DIR"
# drop previous hashed bundles so stale include_bytes sources cannot linger
find "$RELAY_DIR" -mindepth 1 -maxdepth 1 ! -name 'RELAY_REV' -exec rm -rf {} +
cp -R "$work/src/frontend/dist/." "$RELAY_DIR/"
printf '%s\n' "$relay_rev" > "$RELAY_REV_FILE"
echo "relay assets updated ($relay_rev)"
