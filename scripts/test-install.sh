#!/usr/bin/env sh
# shellcheck shell=dash
set -eu

INSTALL_TEST=1
# shellcheck disable=SC1091
. "$(dirname "$0")/../install.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
ok() { printf 'ok %s\n' "$1"; }

expect_ok() {
    if ! "$@"; then
        fail "expected success: $*"
    fi
}
expect_fail() {
    if "$@"; then
        fail "expected failure: $*"
    fi
}

# --- validators ---
expect_ok validate_source "Rezishon/stalwart"
expect_ok validate_source "https://example.com/releases"
expect_fail validate_source "not a repo"
expect_fail validate_source ""

expect_ok validate_version "latest"
expect_ok validate_version "v0.16.25-rl1"
expect_fail validate_version "bad tag!"

expect_ok validate_prefix "/usr/local"
expect_ok validate_prefix "/opt/stalwart"
expect_fail validate_prefix "/"
expect_fail validate_prefix "/usr"
expect_fail validate_prefix "relative"

expect_ok validate_user "stalwart"
expect_ok validate_user "_mail"
expect_fail validate_user "Root"
expect_fail validate_user "this-name-is-way-too-long-for-posix"

expect_ok validate_hostname "mail.example.org"
expect_ok validate_hostname "192.168.1.8"
expect_fail validate_hostname "-bad"
expect_fail validate_hostname "has space"

expect_ok validate_public_url "https://mail.example.org"
expect_ok validate_public_url "http://192.168.1.8:8080"
expect_fail validate_public_url "mail.example.org"
expect_fail validate_public_url "ftp://x"

expect_ok validate_admin "random"
expect_ok validate_admin "admin:twelvechars"
expect_fail validate_admin "admin:short"
expect_fail validate_admin "adminonly"
expect_fail validate_admin ":twelvecharsxx"

expect_ok validate_mode "1"
expect_ok validate_mode "2"
expect_ok validate_mode "3"
expect_fail validate_mode "0"
expect_ok validate_yes_no "Y"
expect_ok validate_yes_no "n"
expect_fail validate_yes_no "maybe"
ok validators

# --- mapping ---
[ "$(artifact_target Linux x86_64)" = "x86_64-linux" ] || fail linux-x64
[ "$(artifact_target Linux aarch64)" = "aarch64-linux" ] || fail linux-arm64
[ "$(artifact_target Linux armv7l)" = "armv7-linux" ] || fail linux-armv7
[ "$(artifact_target FreeBSD amd64)" = "x86_64-freebsd" ] || fail freebsd
if artifact_target Darwin x86_64 >/dev/null 2>&1; then
    fail darwin-should-fail
fi
ok artifact_target

# --- urls ---
[ "$(download_url Rezishon/stalwart latest x86_64-linux)" = \
    "https://github.com/Rezishon/stalwart/releases/latest/download/stalwart-x86_64-linux.tar.gz" ] || fail url-latest
[ "$(download_url Rezishon/stalwart v0.16.25-rl1 aarch64-linux)" = \
    "https://github.com/Rezishon/stalwart/releases/download/v0.16.25-rl1/stalwart-aarch64-linux.tar.gz" ] || fail url-tag
[ "$(download_url https://example.com/dl latest x86_64-linux)" = \
    "https://example.com/dl/stalwart-x86_64-linux.tar.gz" ] || fail url-custom
ok download_url

# --- paths ---
eval "$(resolve_paths /usr/local linux)"
[ "$_bin_dir" = "/usr/local/bin" ] || fail fhs-bin
[ "$_conf_dir" = "/etc/stalwart" ] || fail fhs-conf
[ "$_data_dir" = "/var/lib/stalwart" ] || fail fhs-data
[ "$_log_dir" = "/var/log/stalwart" ] || fail fhs-log

eval "$(resolve_paths /usr/local freebsd)"
[ "$_conf_dir" = "/usr/local/etc/stalwart" ] || fail fbsd-conf
[ "$_data_dir" = "/var/db/stalwart" ] || fail fbsd-data

eval "$(resolve_paths /opt/mail linux)"
[ "$_bin_dir" = "/opt/mail/bin" ] || fail custom-bin
[ "$_conf_dir" = "/opt/mail/etc" ] || fail custom-conf
[ "$_data_dir" = "/opt/mail/data" ] || fail custom-data
ok resolve_paths

# --- env merge (mode 2) ---
_tmp="$(mktemp)"
cat > "$_tmp" <<'EOF'
#STALWART_HOSTNAME=old.example
STALWART_ROLE=primary
#STALWART_RECOVERY_ADMIN=admin:changeme
EOF
upsert_env "$_tmp" STALWART_HOSTNAME mail.example.org
grep -q '^STALWART_HOSTNAME=mail.example.org$' "$_tmp" || fail upsert-uncomment
grep -q '^STALWART_ROLE=primary$' "$_tmp" || fail upsert-keep-other
grep -q '^#STALWART_RECOVERY_ADMIN=admin:changeme$' "$_tmp" || fail upsert-leave-admin
upsert_env "$_tmp" STALWART_PUBLIC_URL https://mail.example.org
grep -q '^STALWART_PUBLIC_URL=https://mail.example.org$' "$_tmp" || fail upsert-append
rm -f "$_tmp"
ok upsert_env

printf 'ALL PASSED\n'
