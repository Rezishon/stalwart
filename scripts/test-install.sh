#!/usr/bin/env sh
# shellcheck shell=dash
set -eu

INSTALL_TEST=1
_install="$(dirname "$0")/../install.sh"
# shellcheck disable=SC1091
. "$_install"

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
expect_ok validate_mode "4"
expect_fail validate_mode "0"
expect_fail validate_mode "5"
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
    "https://github.com/Rezishon/stalwart/releases/latest/download/mailiam-x86_64-linux.tar.gz" ] || fail url-latest
[ "$(download_url Rezishon/stalwart v0.16.25-rl1 aarch64-linux)" = \
    "https://github.com/Rezishon/stalwart/releases/download/v0.16.25-rl1/mailiam-aarch64-linux.tar.gz" ] || fail url-tag
[ "$(download_url https://example.com/dl latest x86_64-linux)" = \
    "https://example.com/dl/mailiam-x86_64-linux.tar.gz" ] || fail url-custom
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
[ "$_legacy_conf" = "/etc/stalwart" ] || fail fhs-legacy-conf

eval "$(resolve_paths /usr/local freebsd)"
[ "$_conf_dir" = "/usr/local/etc/mailiam" ] || fail fbsd-conf
[ "$_data_dir" = "/var/db/mailiam" ] || fail fbsd-data
[ "$_legacy_conf" = "/usr/local/etc/stalwart" ] || fail fbsd-legacy-conf

eval "$(resolve_paths /opt/mail linux)"
[ "$_bin_dir" = "/opt/mail/bin" ] || fail custom-bin
[ "$_conf_dir" = "/opt/mail/etc" ] || fail custom-conf
[ "$_data_dir" = "/opt/mail/data" ] || fail custom-data
[ -z "$_legacy_conf" ] || fail custom-legacy-conf
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
grep -q "^MAILIAM_HOSTNAME='mail.example.org'$" "$_tmp" || fail env-host
grep -q "^MAILIAM_LISTEN_SMTP='25'$" "$_tmp" || fail env-25
grep -q "^MAILIAM_LISTEN_SUBMISSION='587'$" "$_tmp" || fail env-587
grep -q "^MAILIAM_LISTEN_HTTP='8080'$" "$_tmp" || fail env-http
grep -q "^MAILIAM_TLS='true'$" "$_tmp" || fail env-tls
grep -q "^MAILIAM_DC_IMAP_HOST='mail.example.org'$" "$_tmp" || fail env-dc-imap
grep -q "^MAILIAM_DC_SMTP_PORT='465'$" "$_tmp" || fail env-dc-smtp-port
grep -q "^MAILIAM_DC_IC='3'$" "$_tmp" || fail env-ic
if grep -q '^MAILIAM_RECOVERY_MODE=' "$_tmp"; then fail no-recovery-mode; fi
if grep -q '^MAILIAM_RECOVERY_ADMIN=' "$_tmp"; then fail no-admin-when-random; fi
if grep -q '^STALWART_HOSTNAME=' "$_tmp"; then fail no-old-host; fi
_mode=$(stat -c '%a' "$_tmp" 2>/dev/null || stat -f '%OLp' "$_tmp")
[ "$_mode" = 640 ] || fail env-mode
_admin='ops:twelvecharsx'
write_env_file "$_tmp"
grep -q "^MAILIAM_RECOVERY_ADMIN='ops:twelvecharsx'$" "$_tmp" || fail env-admin
_dc_imap_host=
write_env_file "$_tmp"
if grep -q '^MAILIAM_DC_' "$_tmp"; then fail dc-env-emitted-when-empty; fi
_admin=
rm -f "$_tmp"
ok write_env_file

sh "$_install" --help | grep -q -- '--imap-port' || fail help-imap

# no TTY, no -y
if sh "$_install" --prefix /tmp/nope 2>/dev/null; then
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
_tmp_mail="$(mktemp)"
cat > "$_tmp_mail" <<'EOF'
MAILIAM_RECOVERY_MODE_PORT='9191'
EOF
[ "$(recovery_port "$_tmp_mail")" = 9191 ] || fail recovery-mailiam

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
MAILIAM_HOSTNAME='mail.example.org'
MAILIAM_RECOVERY_ADMIN='admin:twelvecharsx'
EOF
apply_mode2_admin "$_tmp"
grep -q "^MAILIAM_RECOVERY_ADMIN='admin:twelvecharsx'$" "$_tmp" || fail mode2-admin-keep
_admin=random
apply_mode2_admin "$_tmp"
grep -q "^#MAILIAM_RECOVERY_ADMIN='admin:twelvecharsx'$" "$_tmp" || fail mode2-admin-random
_admin='ops:twelvecharsx'
apply_mode2_admin "$_tmp"
grep -q "^MAILIAM_RECOVERY_ADMIN='ops:twelvecharsx'$" "$_tmp" || fail mode2-admin-set

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
rm -f "$_tmp" "$_tmp2" "$_tmp3" "$_tmp4" "$_tmp_mail"
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

# --- prompt styling consistency ---
if grep -E '(prompt_yes_no|confirm_or_abort).*\[[yYnN]/[yYnN]\]' "$_install"; then
    fail prompt-redundant-brackets
fi
_got_pyn=$(printf '\n' | { prompt_yes_no _pyn_test Y "Proceed with install?" > "$_WORKDIR/pyn.out"; printf '%s\n' "$_pyn_test"; })
[ "$_got_pyn" = Y ] || fail pyn-default
grep -q 'Proceed with install? (Default: Y): ' "$_WORKDIR/pyn.out" || fail pyn-format
ok prompt_styling

_pw=$(generate_password)
[ "${#_pw}" -eq 16 ] || fail gen-pw-len
printf '%s' "$_pw" | grep -Eq '^[A-Za-z0-9]{16}$' || fail gen-pw-alnum
_admin=
ensure_generated_admin
[ "${_admin#admin:}" != "$_admin" ] || fail gen-admin-prefix
[ "${#_admin}" -eq 22 ] || fail gen-admin-len
ok generate-admin

print_banner | grep -q '███▄ ▄███▓' || fail banner-art
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

[ "$(init_from_hints freebsd n n n)" = freebsd ] || fail init-fbsd
[ "$(init_from_hints linux y n n)" = systemd ] || fail init-systemd
[ "$(init_from_hints linux n y n)" = openrc ] || fail init-openrc
[ "$(init_from_hints linux n n y)" = sysv ] || fail init-sysv
[ "$(init_from_hints linux n n n)" = none ] || fail init-none
[ "$(init_from_hints linux y y y)" = systemd ] || fail init-systemd-wins
[ "$(init_from_hints darwin y y y)" = none ] || fail init-other
ok init_from_hints

printf 'old\n' > "$_WORKDIR/bin-dest"
printf 'new\n' > "$_WORKDIR/bin-src"
replace_binary "$_WORKDIR/bin-dest" "$_WORKDIR/bin-src"
[ "$(cat "$_WORKDIR/bin-dest")" = new ] || fail replace-body
[ ! -e "$_WORKDIR/bin-dest.new.$$" ] || fail replace-leftover
ok replace_binary

_from_ver=0.16.25-rl1.0.18
_to_ver=0.16.25-rl1.0.19
_bin_file=/usr/local/bin/mailiam
_init=sysv
_log_dir=/var/log/mailiam
NO_COLOR=1 init_colors
print_update_success > "$_WORKDIR/upd.out"
grep -q '0.16.25-rl1.0.18 => 0.16.25-rl1.0.19' "$_WORKDIR/upd.out" || fail update-from-to
ok print_update_success

_init=none
_bin_file=/usr/local/bin/mailiam
_config_file=/etc/mailiam/config.json
_env_file=/etc/mailiam/mailiam.env
_log_dir=/var/log/mailiam
NO_COLOR=1 init_colors
print_service_hints > "$_WORKDIR/hints.out"
grep -q 'mailiam --config=/etc/mailiam/config.json' "$_WORKDIR/hints.out" || fail none-hints-start
grep -q 'mailiam.env' "$_WORKDIR/hints.out" || fail none-hints-env
if grep -q 'service mailiam' "$_WORKDIR/hints.out"; then fail none-hints-no-service; fi
ok print_service_hints-none

# --- uninstall & step runner helpers ---
_bin_file=/usr/local/bin/mailiam
_conf_dir=/etc/mailiam
_data_dir=/var/lib/mailiam
_log_dir=/var/log/mailiam
_account=mailiam
_init=systemd
_purge=0
NO_COLOR=1 init_colors
print_uninstall_summary > "$_WORKDIR/un_summary_keep.out"
grep -q 'MailiaM Uninstall Summary' "$_WORKDIR/un_summary_keep.out" || fail un-summary-title
grep -q 'mailiam.service (Stopped & Removed)' "$_WORKDIR/un_summary_keep.out" || fail un-summary-svc
grep -q '/etc/mailiam (Preserved)' "$_WORKDIR/un_summary_keep.out" || fail un-summary-keep

_purge=1
print_uninstall_summary > "$_WORKDIR/un_summary_purge.out"
grep -q '/etc/mailiam (Purged)' "$_WORKDIR/un_summary_purge.out" || fail un-summary-purge

_purge=0
_step_failures=0
print_uninstall_success > "$_WORKDIR/un_succ_keep.out"
grep -q 'MailiaM Uninstalled Successfully' "$_WORKDIR/un_succ_keep.out" || fail un-succ-title
grep -q 'Preserved in /var/lib/mailiam and /etc/mailiam' "$_WORKDIR/un_succ_keep.out" || fail un-succ-keep
grep -q 'Service Account:   mailiam (removed)' "$_WORKDIR/un_succ_keep.out" || fail un-succ-acct-rm

_purge=1
print_uninstall_success > "$_WORKDIR/un_succ_purge.out"
grep -q 'Mail Data & Conf:  Purged' "$_WORKDIR/un_succ_purge.out" || fail un-succ-purge

# Failure handling in print_uninstall_success
_step_failures=2
print_uninstall_success > "$_WORKDIR/un_succ_warn.out"
grep -q 'MailiaM Uninstallation Completed with Warnings' "$_WORKDIR/un_succ_warn.out" || fail un-warn-title
grep -q 'Completed with warnings - see /tmp/mailiam-uninstall.log' "$_WORKDIR/un_succ_warn.out" || fail un-warn-msg
_step_failures=0

# System account safety
expect_ok is_system_account root
expect_ok is_system_account daemon
expect_ok is_system_account bin
expect_ok is_system_account nobody
expect_fail is_system_account mailiam
expect_fail is_system_account customuser
expect_fail is_system_account ""
_account=root
uninstall_account
print_uninstall_success > "$_WORKDIR/un_succ_root.out"
grep -q 'Service Account:   root (preserved - system account)' "$_WORKDIR/un_succ_root.out" || fail un-root-preserved
_account=mailiam

# Unified run_step tests
_step_failures=0
run_step 1 6 "Setting up service account (mailiam)..." true > "$_WORKDIR/step_uni.out"
grep -q '\[1/6\] Setting up service account (mailiam)...' "$_WORKDIR/step_uni.out" || fail step-uni-desc
grep -q '\[OK\]' "$_WORKDIR/step_uni.out" || fail step-uni-ok
[ "$_step_failures" -eq 0 ] || fail step-uni-failures-zero

# run_step binary progress mode with file fallback
_file="/tmp/dummy.tar.gz"
run_step 3 6 "Installing binary..." true > "$_WORKDIR/step_uni_file.out"
grep -q '\[3/6\] Installing binary...' "$_WORKDIR/step_uni_file.out" || fail step-uni-file-desc
grep -q '\[OK\]' "$_WORKDIR/step_uni_file.out" || fail step-uni-file-ok
_file=""

run_step 2 6 "Testing failing step..." false > "$_WORKDIR/step_uni_fail.out" || true
grep -q '\[2/6\] Testing failing step...' "$_WORKDIR/step_uni_fail.out" || fail step-uni-fail-desc
grep -q '\[FAILED\]' "$_WORKDIR/step_uni_fail.out" || fail step-uni-fail-tag
[ "$_step_failures" -eq 1 ] || fail step-uni-failures-inc
_step_failures=0

# Custom logging in run_step
_test_steplog="$_WORKDIR/step_custom.log"
_step_log="$_test_steplog"
run_step 3 6 "Testing custom step log..." true > "$_WORKDIR/step_custom.out"
grep -q 'Step \[3/6\]: Testing custom step log...' "$_test_steplog" || fail step-custom-log-start
grep -q 'Step \[3/6\]: SUCCESS' "$_test_steplog" || fail step-custom-log-succ
run_step 4 6 "Testing custom step log fail..." sh -c 'echo "inner error msg" >&2; exit 3' > "$_WORKDIR/step_custom_fail.out" 2>&1 || true
grep -q 'Step \[4/6\]: FAILED (exit code 3)' "$_test_steplog" || fail step-custom-log-fail
grep -q 'error: inner error msg' "$_test_steplog" || fail step-custom-log-err-msg
_step_log=

# run_uninstall_step backward compatibility
_log=/tmp/mailiam-uninstall.log
rm -f "$_log"
run_uninstall_step 1 5 "Testing step runner..." true > "$_WORKDIR/step.out"
grep -q '\[1/5\] Testing step runner...' "$_WORKDIR/step.out" || fail step-out
grep -q '\[OK\]' "$_WORKDIR/step.out" || fail step-ok
grep -q 'Step \[1/5\]: SUCCESS' "$_log" || fail step-log

run_uninstall_step 2 5 "Testing failing step..." false > "$_WORKDIR/step_fail.out" || true
grep -q '\[2/5\] Testing failing step...' "$_WORKDIR/step_fail.out" || fail step-fail-out
grep -q '\[FAILED\]' "$_WORKDIR/step_fail.out" || fail step-failed
grep -q 'Step \[2/5\]: FAILED' "$_log" || fail step-fail-log
rm -f "$_log"

_test_conf="$_WORKDIR/test_conf"
_test_data="$_WORKDIR/test_data"
_test_log="$_WORKDIR/test_log"
mkdir -p "$_test_conf" "$_test_data" "$_test_log"
_conf_dir="$_test_conf"
_data_dir="$_test_data"
_log_dir="$_test_log"
_purge=0
uninstall_data
[ -d "$_test_conf" ] && [ -d "$_test_data" ] && [ -d "$_test_log" ] || fail un-data-preserved

# Legacy symlink purge
_test_legacy="$_WORKDIR/test_legacy_symlink"
ln -s "$_test_conf" "$_test_legacy"
_legacy_conf="$_test_legacy"
_purge=1
uninstall_data
[ ! -d "$_test_conf" ] && [ ! -d "$_test_data" ] && [ ! -d "$_test_log" ] || fail un-data-purged
[ ! -e "$_test_legacy" ] && [ ! -L "$_test_legacy" ] || fail un-legacy-purged

_test_bin="$_WORKDIR/mailiam"
_test_bak="$_WORKDIR/mailiam.bak"
_test_compat="$_WORKDIR/mailiam-compat"
touch "$_test_bin" "$_test_bak"
ln -s mailiam "$_test_compat"
_bin_file="$_test_bin"
_bin_legacy="$_test_compat"
uninstall_executables
[ ! -e "$_test_bin" ] && [ ! -e "$_test_bak" ] && [ ! -e "$_test_compat" ] || fail un-exec-removed
ok uninstall-helpers

# --- CLI flags parsing ---
_parsed=$(
    (
        INSTALL_TEST=1
        . "$_install"
        id() { printf '0\n'; }
        uninstall_mailiam() {
            printf 'mode=%s uninstall=%s purge=%s\n' "$_install_mode" "$_uninstall" "$_purge"
        }
        main -y --uninstall --purge
    )
)
[ "$_parsed" = "mode=4 uninstall=1 purge=1" ] || fail cli-flags-uninstall-purge

_parsed2=$(
    (
        INSTALL_TEST=1
        . "$_install"
        id() { printf '0\n'; }
        uninstall_mailiam() {
            printf 'mode=%s uninstall=%s purge=%s\n' "$_install_mode" "$_uninstall" "$_purge"
        }
        main -y -d
    )
)
[ "$_parsed2" = "mode=4 uninstall=1 purge=0" ] || fail cli-flags-d-keep
ok cli-flags

# --- CLI guards ---
if sh "$_install" --not-a-flag 2>/dev/null; then fail unknown-flag; fi
if sh "$_install" --prefix /opt/a /opt/b 2>/dev/null; then fail extra-positional; fi
if sh "$_install" --repo 2>/dev/null; then fail missing-flag-value; fi
if sh "$_install" -y --admin short 2>/dev/null; then fail cli-admin-short; fi
sh "$_install" --help | grep -q -- '--uninstall' || fail help-uninstall
sh "$_install" --help | grep -q -- '--purge' || fail help-purge
if sh "$_install" --uninstall-bogus 2>/dev/null; then fail cli-unknown-uninstall-flag; fi
if sh "$_install" --uninstall 2>/dev/null; then fail cli-uninstall-no-yes; fi
ok cli-guards

printf 'ALL PASSED\n'
