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

_WORKDIR=$(mktemp -d)
cleanup() { rm -rf "$_WORKDIR"; }
trap cleanup EXIT INT HUP

# --- validators ---
expect_ok validate_source "Rezishon/mailiam"
expect_ok validate_source "https://example.com/releases"
: > "$_WORKDIR/dummy.tar.gz"
expect_ok validate_source "$_WORKDIR/dummy.tar.gz"
expect_fail validate_source "$_WORKDIR/missing.tar.gz"
expect_fail validate_source "http://example.com/releases"
expect_fail validate_source "not a repo"
expect_fail validate_source ""

expect_ok validate_version "latest"
expect_ok validate_version "v0.16.25-rl1"
expect_fail validate_version "bad tag!"

expect_ok validate_prefix "/usr/local"
expect_ok validate_prefix "/opt/mailiam"
expect_fail validate_prefix "/"
expect_fail validate_prefix "/usr"
expect_fail validate_prefix "/bin"
expect_fail validate_prefix "/dev"
expect_fail validate_prefix "/proc"
expect_fail validate_prefix "relative"
expect_fail validate_prefix "/opt/has'quote"

expect_ok validate_user "mailiam"
expect_ok validate_user "_mail"
expect_fail validate_user "Root"
expect_fail validate_user "this-name-is-way-too-long-for-posix"

expect_ok validate_hostname "mail.example.org"
expect_ok validate_hostname "192.168.1.8"
expect_fail validate_hostname "-bad"
expect_fail validate_hostname "has space"
expect_ok validate_email "admin@mail.example.org"
expect_fail validate_email "admin"
expect_fail validate_email "admin@localhost"

expect_ok validate_public_url "https://mail.example.org"
expect_ok validate_public_url "http://192.168.1.8:8080"
expect_fail validate_public_url "mail.example.org"
expect_fail validate_public_url "ftp://x"

expect_ok validate_admin "random"
expect_ok validate_admin "admin:twelvecharss"
expect_fail validate_admin "admin:twelvechars"
expect_fail validate_admin "admin:short"
expect_fail validate_admin "adminonly"
expect_fail validate_admin ":twelvecharsxx"

expect_ok validate_mode "1"
expect_ok validate_mode "2"
expect_ok validate_mode "3"
expect_fail validate_mode "0"
expect_ok validate_yes_no "Y"
expect_ok validate_yes_no "yes"
expect_ok validate_yes_no "NO"
expect_ok validate_yes_no "n"
expect_fail validate_yes_no "maybe"

expect_ok validate_port 0
expect_ok validate_port 65535
expect_fail validate_port 65536
expect_fail validate_port -1
expect_ok validate_dc_security ssl
expect_ok validate_dc_security starttls
expect_ok validate_dc_security default
expect_ok validate_dc_security plain
expect_fail validate_dc_security bogus
expect_ok validate_dc_ic 0
expect_ok validate_dc_ic 1
expect_ok validate_dc_ic 3
expect_fail validate_dc_ic 2
ok validators

expect_fail contains_cr_lf_or_quote ok
expect_ok contains_cr_lf_or_quote "has'quote"
expect_ok contains_cr_lf_or_quote "$(printf 'a\nb')"
[ "$(quote_env_value hello)" = "'hello'" ] || fail quote-ok
expect_fail quote_env_value "has'quote"
expect_ok is_yes Y
expect_ok is_yes yes
expect_fail is_yes n
expect_fail is_yes no
ok quote-is-yes

# --- mapping ---
[ "$(artifact_target Linux x86_64)" = "x86_64-linux" ] || fail linux-x64
[ "$(artifact_target Linux aarch64)" = "aarch64-linux" ] || fail linux-arm64
[ "$(artifact_target Linux arm64)" = "aarch64-linux" ] || fail linux-arm64-alias
[ "$(artifact_target Linux armv7l)" = "armv7-linux" ] || fail linux-armv7
[ "$(artifact_target Linux armv7)" = "armv7-linux" ] || fail linux-armv7-alias
[ "$(artifact_target FreeBSD amd64)" = "x86_64-freebsd" ] || fail freebsd
[ "$(artifact_target FreeBSD x86_64)" = "x86_64-freebsd" ] || fail freebsd-x64
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
if download_url http://example.com/dl latest x86_64-linux >/dev/null 2>&1; then
    fail url-http
fi
ok download_url

# --- paths ---
eval "$(resolve_paths /usr/local linux)"
[ "$_bin_dir" = "/usr/local/bin" ] || fail fhs-bin
[ "$_conf_dir" = "/etc/mailiam" ] || fail fhs-conf
[ "$_data_dir" = "/var/lib/mailiam" ] || fail fhs-data
[ "$_log_dir" = "/var/log/mailiam" ] || fail fhs-log

eval "$(resolve_paths /usr/local freebsd)"
[ "$_conf_dir" = "/usr/local/etc/mailiam" ] || fail fbsd-conf
[ "$_data_dir" = "/var/db/mailiam" ] || fail fbsd-data

eval "$(resolve_paths /opt/mail linux)"
[ "$_bin_dir" = "/opt/mail/bin" ] || fail custom-bin
[ "$_conf_dir" = "/opt/mail/etc" ] || fail custom-conf
[ "$_data_dir" = "/opt/mail/data" ] || fail custom-data
ok resolve_paths

# --- set_env_file ---
_conf_dir="$_WORKDIR/envdir"
mkdir -p "$_conf_dir"
set_env_file
[ "$_env_file" = "$_conf_dir/mailiam.env" ] || fail env-default-mailiam
: > "$_conf_dir/stalwart.env"
set_env_file
[ "$_env_file" = "$_conf_dir/stalwart.env" ] || fail env-legacy-fallback
: > "$_conf_dir/mailiam.env"
set_env_file
[ "$_env_file" = "$_conf_dir/mailiam.env" ] || fail env-prefer-mailiam
ok set_env_file

# --- env merge (mode 2) ---
_tmp="$(mktemp)"
cat > "$_tmp" <<'EOF'
#STALWART_HOSTNAME=old.example
STALWART_ROLE=primary
#STALWART_RECOVERY_ADMIN=admin:changeme
EOF
upsert_env "$_tmp" STALWART_HOSTNAME mail.example.org
grep -q "^STALWART_HOSTNAME='mail.example.org'$" "$_tmp" || fail upsert-uncomment
grep -q '^STALWART_ROLE=primary$' "$_tmp" || fail upsert-keep-other
grep -q '^#STALWART_RECOVERY_ADMIN=admin:changeme$' "$_tmp" || fail upsert-leave-admin
upsert_env "$_tmp" STALWART_PUBLIC_URL https://mail.example.org
grep -q "^STALWART_PUBLIC_URL='https://mail.example.org'$" "$_tmp" || fail upsert-append
rm -f "$_tmp"
ok upsert_env

# --- write_env_file ---
_tmp="$(mktemp)"
_hostname=mail.example.org
_public_url=https://mail.example.org
_listen_smtp=25
_listen_submission=587
_listen_submissions=465
_listen_imap=993
_listen_pop3=995
_listen_sieve=4190
_listen_https=443
_listen_http=8080
_tls=true
_dc_imap_host=mail.example.org
_dc_imap_port=993
_dc_imap_security=ssl
_dc_smtp_host=mail.example.org
_dc_smtp_port=465
_dc_smtp_security=ssl
_dc_ic=3
_admin=
write_env_file "$_tmp"
grep -q "^STALWART_HOSTNAME='mail.example.org'$" "$_tmp" || fail env-host
grep -q "^STALWART_LISTEN_SMTP='25'$" "$_tmp" || fail env-25
grep -q "^STALWART_LISTEN_SUBMISSION='587'$" "$_tmp" || fail env-587
grep -q "^STALWART_LISTEN_HTTP='8080'$" "$_tmp" || fail env-http
grep -q "^STALWART_TLS='true'$" "$_tmp" || fail env-tls
grep -q "^STALWART_DC_IMAP_HOST='mail.example.org'$" "$_tmp" || fail env-dc-imap
grep -q "^STALWART_DC_SMTP_PORT='465'$" "$_tmp" || fail env-dc-smtp-port
grep -q "^STALWART_DC_IC='3'$" "$_tmp" || fail env-ic
if grep -q '^STALWART_RECOVERY_MODE=' "$_tmp"; then fail no-recovery-mode; fi
if grep -q '^STALWART_RECOVERY_ADMIN=' "$_tmp"; then fail no-admin-when-random; fi
_mode=$(stat -c '%a' "$_tmp" 2>/dev/null || stat -f '%OLp' "$_tmp")
[ "$_mode" = 640 ] || fail env-mode
_admin='ops:twelvecharsx'
write_env_file "$_tmp"
grep -q "^STALWART_RECOVERY_ADMIN='ops:twelvecharsx'$" "$_tmp" || fail env-admin
_admin=
rm -f "$_tmp"
ok write_env_file

sh install.sh --help | grep -q -- '--imap-port' || fail help-imap

# no TTY, no -y
if sh install.sh --prefix /tmp/nope 2>/dev/null; then
    fail 'piped install without -y should exit'
fi
ok tty-guard

# --- env-file helpers (mode 1/2) ---
_tmp="$(mktemp)"
cat > "$_tmp" <<'EOF'
STALWART_HOSTNAME='mail.example.org'
STALWART_PUBLIC_URL='https://mail.example.org:8443'
STALWART_LISTEN_HTTPS='8443'
STALWART_LISTEN_HTTP='18080'
STALWART_RECOVERY_MODE_PORT='9090'
STALWART_RECOVERY_ADMIN='admin:twelvecharsx'
EOF
[ "$(read_env_key "$_tmp" STALWART_HOSTNAME)" = mail.example.org ] || fail read-env-host
[ "$(recovery_port "$_tmp")" = 9090 ] || fail recovery-from-env
_tmp2="$(mktemp)"
cat > "$_tmp2" <<'EOF'
STALWART_LISTEN_HTTP='0'
EOF
[ "$(recovery_port "$_tmp2")" = 80 ] || fail recovery-zero-http
_tmp3="$(mktemp)"
cat > "$_tmp3" <<'EOF'
STALWART_LISTEN_HTTP='18080'
EOF
[ "$(recovery_port "$_tmp3")" = 18080 ] || fail recovery-listen-http
[ "$(recovery_port /no/such/env)" = 80 ] || fail recovery-missing

_hostname_arg=
_public_url_arg=
_hostname=detected.local
_public_url=
_listen_https=443
_env_file="$_tmp"
seed_mode2_from_env
[ "$_hostname" = mail.example.org ] || fail seed-hostname
[ "$_public_url" = 'https://mail.example.org:8443' ] || fail seed-public-url

_hostname_arg=
_public_url_arg=
_hostname=detected.local
_public_url=
_listen_https=443
_tmp4="$(mktemp)"
cat > "$_tmp4" <<'EOF'
STALWART_HOSTNAME='mail.example.org'
STALWART_LISTEN_HTTPS='8443'
EOF
_env_file="$_tmp4"
seed_mode2_from_env
[ "$_hostname" = mail.example.org ] || fail seed-host-only
set_public_url_default
[ "$_public_url" = 'https://mail.example.org:8443' ] || fail seed-url-from-https

comment_env_key "$_tmp" STALWART_RECOVERY_ADMIN
grep -q "^#STALWART_RECOVERY_ADMIN='admin:twelvecharsx'$" "$_tmp" || fail comment-admin
grep -q "^STALWART_LISTEN_HTTPS='8443'$" "$_tmp" || fail comment-leave-listen

_file=/opt/keep-me.tar.gz
comment_env_key "$_tmp" STALWART_LISTEN_HTTPS
[ "$_file" = /opt/keep-me.tar.gz ] || fail comment-clobber-file
upsert_env "$_tmp" STALWART_HOSTNAME mail.example.org
[ "$_file" = /opt/keep-me.tar.gz ] || fail upsert-clobber-file

_admin=
cat > "$_tmp" <<'EOF'
STALWART_HOSTNAME='mail.example.org'
STALWART_RECOVERY_ADMIN='admin:twelvecharsx'
EOF
apply_mode2_admin "$_tmp"
grep -q "^STALWART_RECOVERY_ADMIN='admin:twelvecharsx'$" "$_tmp" || fail mode2-admin-keep
_admin=random
apply_mode2_admin "$_tmp"
grep -q "^#STALWART_RECOVERY_ADMIN='admin:twelvecharsx'$" "$_tmp" || fail mode2-admin-random
_admin='ops:twelvecharsx'
apply_mode2_admin "$_tmp"
grep -q "^STALWART_RECOVERY_ADMIN='ops:twelvecharsx'$" "$_tmp" || fail mode2-admin-set

_file=
_repo=
apply_source 'https://example.com/dl/stalwart-x86_64-linux.tar.gz'
[ -z "$_file" ] || fail apply-https-file
[ "$_repo" = 'https://example.com/dl/stalwart-x86_64-linux.tar.gz' ] || fail apply-https-repo
apply_source /opt/mailiam.tar.gz
[ "$_file" = /opt/mailiam.tar.gz ] || fail apply-local
apply_source Rezishon/mailiam
[ -z "$_file" ] || fail apply-repo-file
[ "$_repo" = Rezishon/mailiam ] || fail apply-repo
rm -f "$_tmp" "$_tmp2" "$_tmp3" "$_tmp4"
ok env-helpers

# --- apply_admin_flag / set_dc_defaults ---
_admin=keepme
apply_admin_flag random
[ -z "$_admin" ] || fail apply-admin-random
apply_admin_flag 'ops:twelvecharsx'
[ "$_admin" = 'ops:twelvecharsx' ] || fail apply-admin-set
if (apply_admin_flag 'admin:short') >/dev/null 2>&1; then fail apply-admin-short; fi
if (apply_admin_flag adminonly) >/dev/null 2>&1; then fail apply-admin-nocolon; fi
_admin=

_hostname=mail.example.org
_listen_imap=993
_listen_submissions=465
_dc_imap_host=
_dc_smtp_host=
_dc_imap_port=
_dc_smtp_port=
set_dc_defaults
[ "$_dc_imap_host" = mail.example.org ] || fail dc-imap-host
[ "$_dc_smtp_host" = mail.example.org ] || fail dc-smtp-host
[ "$_dc_imap_port" = 993 ] || fail dc-imap-port
[ "$_dc_smtp_port" = 465 ] || fail dc-smtp-port
_dc_imap_host=other.example
set_dc_defaults
[ "$_dc_imap_host" = other.example ] || fail dc-keep
ok apply-admin-dc

# --- prompt-flow helpers (spec 2026-10-19) ---
NO_COLOR=1 init_colors
[ -z "${CLR_RED}" ] && [ -z "${CLR_BOLD}" ] && [ -z "${CLR_RESET}" ] || fail colors-no-color
unset NO_COLOR
TERM=dumb init_colors
[ -z "${CLR_RED}" ] || fail colors-term-dumb
ok init_colors

[ "$(hostname_default mail.example.com)" = mail.example.com ] || fail hn-fqdn
[ "$(hostname_default 58cc45e5c613)" = mail.localhost ] || fail hn-nodot
[ "$(hostname_default "")" = mail.localhost ] || fail hn-empty
ok hostname_default

[ "$(tag_from_release_url 'https://github.com/Rezishon/stalwart/releases/tag/v0.16.25-rl1.0.20')" = \
    v0.16.25-rl1.0.20 ] || fail tag-from-url
[ "$(tag_from_release_url 'https://github.com/Rezishon/stalwart/releases/latest')" = latest ] || fail tag-latest-url
ok tag_from_release_url

_hostname=mail.example.com
_public_url=
_tls=true
_listen_https=443
_listen_http=80
set_public_url_default
[ "$_public_url" = 'https://mail.example.com' ] || fail url-https-std
_public_url=
_listen_https=8443
set_public_url_default
[ "$_public_url" = 'https://mail.example.com:8443' ] || fail url-https-custom
_public_url=
_tls=false
_listen_http=80
set_public_url_default
[ "$_public_url" = 'http://mail.example.com' ] || fail url-http-std
_public_url=
_listen_http=8080
set_public_url_default
[ "$_public_url" = 'http://mail.example.com:8080' ] || fail url-http-custom
ok set_public_url_default

_hostname=mail.example.com
_tls=true
_dc_imap_host= _dc_smtp_host= _dc_imap_port= _dc_smtp_port=
_dc_imap_security= _dc_smtp_security= _dc_ic=
_listen_imap=143
_listen_submissions=465
_listen_submission=587
set_dc_defaults
[ "$_dc_imap_port" = 993 ] || fail dc-tls-imap
[ "$_dc_smtp_port" = 465 ] || fail dc-tls-smtp
[ "$_dc_imap_security" = ssl ] || fail dc-tls-imap-sec
[ "$_dc_smtp_security" = ssl ] || fail dc-tls-smtp-sec
[ "$_dc_ic" = 3 ] || fail dc-tls-ic
_tls=false
_dc_imap_host= _dc_smtp_host= _dc_imap_port= _dc_smtp_port=
_dc_imap_security= _dc_smtp_security= _dc_ic=
set_dc_defaults
[ "$_dc_imap_port" = 143 ] || fail dc-plain-imap
[ "$_dc_smtp_port" = 587 ] || fail dc-plain-smtp
[ "$_dc_imap_security" = plain ] || fail dc-plain-imap-sec
[ "$_dc_smtp_security" = plain ] || fail dc-plain-smtp-sec
[ "$_dc_ic" = 0 ] || fail dc-plain-ic
ok set_dc_defaults-tls

_got=$(printf '\n' | { prompt_choice _c 1 3 "Choice [1-3]" >/dev/null; printf '%s\n' "$_c"; })
[ "$_got" = 1 ] || fail choice-default
_got=$(printf '2\n' | { prompt_choice _c 1 3 "Choice [1-3]" >/dev/null; printf '%s\n' "$_c"; })
[ "$_got" = 2 ] || fail choice-2
_got=$(printf '9\n3\n' | { prompt_choice _c 1 3 "Choice [1-3]" >/dev/null; printf '%s\n' "$_c"; })
[ "$_got" = 3 ] || fail choice-retry
ok prompt_choice

print_banner | grep -q 'Welcome to MailiaM.' || fail banner-welcome
ok print_banner

# --- extract_mailiam (tmpdir only) ---
_src="$_WORKDIR/src"
_out="$_WORKDIR/out"
mkdir -p "$_src" "$_out"
printf 'stub\n' > "$_src/mailiam"
tar -C "$_src" -czf "$_WORKDIR/good.tar.gz" mailiam
extract_mailiam "$_WORKDIR/good.tar.gz" "$_out"
[ -f "$_out/mailiam" ] && [ ! -L "$_out/mailiam" ] || fail extract-ok
[ "$(cat "$_out/mailiam")" = stub ] || fail extract-body
rm -f "$_out/mailiam"

printf 'legacy\n' > "$_src/stalwart"
tar -C "$_src" -czf "$_WORKDIR/legacy.tar.gz" stalwart
extract_mailiam "$_WORKDIR/legacy.tar.gz" "$_out"
[ -f "$_out/stalwart" ] && [ ! -L "$_out/stalwart" ] || fail extract-legacy
[ "$(cat "$_out/stalwart")" = legacy ] || fail extract-legacy-body
rm -f "$_out/stalwart"

printf 'extra\n' > "$_src/extra"
tar -C "$_src" -czf "$_WORKDIR/extra.tar.gz" mailiam extra
if (extract_mailiam "$_WORKDIR/extra.tar.gz" "$_out") >/dev/null 2>&1; then
    fail extract-extra-members
fi

tar -C "$_src" -czf "$_WORKDIR/dotdot.tar.gz" --transform 's|^|../|' mailiam
if (extract_mailiam "$_WORKDIR/dotdot.tar.gz" "$_out") >/dev/null 2>&1; then
    fail extract-dotdot
fi
ok extract_mailiam

# --- CLI (subprocess; never reaches root install) ---
_install="$(dirname "$0")/../install.sh"
if sh "$_install" --not-a-flag 2>/dev/null; then fail unknown-flag; fi
if sh "$_install" --prefix /opt/a /opt/b 2>/dev/null; then fail extra-positional; fi
if sh "$_install" --repo 2>/dev/null; then fail missing-flag-value; fi
if sh "$_install" -y --admin short 2>/dev/null; then fail cli-admin-short; fi
ok cli-guards

printf 'ALL PASSED\n'
