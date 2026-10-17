#!/usr/bin/env sh
# shellcheck shell=dash

#
# SPDX-FileCopyrightText: 2020 Stalwart Labs LLC <hello@stalw.art>
#
# SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
#

# Stalwart install script -- based on the rustup installation script.

set -e
set -u

readonly BASE_URL="https://github.com/stalwartlabs/stalwart/releases/latest/download"

contains_cr_lf_or_quote() {
    case "$1" in *\'*) return 0 ;; esac
    _stripped=$(printf '%s' "$1" | tr -d '\n\r')
    [ "$1" != "$_stripped" ]
}

quote_env_value() {
    if contains_cr_lf_or_quote "$1"; then
        return 1
    fi
    printf "'%s'\n" "$1"
}

validate_source() {
    [ -n "$1" ] || return 1
    case "$1" in
        http://*) return 1 ;;
        https://*) return 0 ;;
        *.tar.gz)
            [ -r "$1" ] || return 1
            return 0
            ;;
    esac
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
}

validate_version() {
    if [ "$1" = latest ]; then
        return 0
    fi
    [ -n "$1" ] || return 1
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]+$'
}

validate_prefix() {
    case "$1" in
        /*) ;;
        *) return 1 ;;
    esac
    if contains_cr_lf_or_quote "$1"; then
        return 1
    fi
    case "$1" in
        *[!A-Za-z0-9/._-]*) return 1 ;;
    esac
    case "$1" in
        /|/bin|/sbin|/lib|/usr|/dev|/proc|/sys) return 1 ;;
    esac
    return 0
}

validate_user() {
    [ "${#1}" -ge 1 ] && [ "${#1}" -le 32 ] || return 1
    printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]*$'
}

validate_hostname() {
    [ -n "$1" ] || return 1
    case "$1" in
        *[!A-Za-z0-9.-]*|-*|*-|.*|*.|*..*) return 1 ;;
    esac
    return 0
}

validate_public_url() {
    case "$1" in
        https://?*|http://?*) return 0 ;;
        *) return 1 ;;
    esac
}

validate_admin() {
    if [ "$1" = random ]; then
        return 0
    fi
    if contains_cr_lf_or_quote "$1"; then
        return 1
    fi
    case "$1" in
        *:*) ;;
        *) return 1 ;;
    esac
    _user="${1%%:*}"
    _pass="${1#*:}"
    [ -n "$_user" ] || return 1
    printf '%s' "$_user" | grep -Eq '^[A-Za-z0-9_-]+$' || return 1
    [ "${#_pass}" -ge 12 ]
}

validate_mode() {
    case "$1" in
        1|2|3) return 0 ;;
        *) return 1 ;;
    esac
}

validate_yes_no() {
    case "$1" in
        [Yy]|[Yy][Ee][Ss]|[Nn]|[Nn][Oo]) return 0 ;;
        *) return 1 ;;
    esac
}

validate_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 0 ] && [ "$1" -le 65535 ]
}

validate_dc_security() {
    case "$1" in
        ssl|starttls|default|plain) return 0 ;;
        *) return 1 ;;
    esac
}

validate_dc_ic() {
    case "$1" in
        0|1|3) return 0 ;;
        *) return 1 ;;
    esac
}

artifact_target() {
    case "$1" in
        Darwin) return 1 ;;
        Linux)
            case "$2" in
                x86_64) printf '%s\n' x86_64-linux ;;
                aarch64|arm64) printf '%s\n' aarch64-linux ;;
                armv7l|armv7) printf '%s\n' armv7-linux ;;
                *) return 1 ;;
            esac
            ;;
        FreeBSD)
            case "$2" in
                amd64|x86_64) printf '%s\n' x86_64-freebsd ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

download_url() {
    _src="$1"
    _tag="$2"
    _target="$3"
    case "$_src" in
        http://*) return 1 ;;
        https://*)
            printf '%s\n' "${_src%/}/stalwart-${_target}.tar.gz"
            ;;
        *)
            if [ "$_tag" = latest ]; then
                printf '%s\n' "https://github.com/${_src}/releases/latest/download/stalwart-${_target}.tar.gz"
            else
                printf '%s\n' "https://github.com/${_src}/releases/download/${_tag}/stalwart-${_target}.tar.gz"
            fi
            ;;
    esac
}

resolve_paths() {
    _prefix="$1"
    _os="$2"
    if contains_cr_lf_or_quote "$_prefix"; then
        return 1
    fi
    if [ "$_prefix" = /usr/local ]; then
        _bin_dir=/usr/local/bin
        _log_dir=/var/log/stalwart
        if [ "$_os" = freebsd ]; then
            _conf_dir=/usr/local/etc/stalwart
            _data_dir=/var/db/stalwart
        else
            _conf_dir=/etc/stalwart
            _data_dir=/var/lib/stalwart
        fi
    else
        _bin_dir="${_prefix}/bin"
        _conf_dir="${_prefix}/etc"
        _log_dir="${_prefix}/logs"
        _data_dir="${_prefix}/data"
    fi
    if contains_cr_lf_or_quote "$_bin_dir" || contains_cr_lf_or_quote "$_conf_dir" \
        || contains_cr_lf_or_quote "$_data_dir" || contains_cr_lf_or_quote "$_log_dir"; then
        return 1
    fi
    printf "_bin_dir='%s'\n_conf_dir='%s'\n_data_dir='%s'\n_log_dir='%s'\n" \
        "$_bin_dir" "$_conf_dir" "$_data_dir" "$_log_dir"
}

upsert_env() {
    _file="$1"
    _key="$2"
    _value="$3"
    if ! quote_env_value "$_value" >/dev/null; then
        return 1
    fi
    _out=$(mktemp)
    _found=0
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            "${_key}="*|"#${_key}="*)
                printf '%s=%s\n' "$_key" "'$_value'"
                _found=1
                ;;
            *)
                printf '%s\n' "$_line"
                ;;
        esac
    done < "$_file" > "$_out"
    if [ "$_found" -eq 0 ]; then
        printf '%s=%s\n' "$_key" "'$_value'" >> "$_out"
    fi
    cat "$_out" > "$_file"
    rm -f "$_out"
}
main() {
    local _os _uname _account=""
    local _component="stalwart"
    local _prefix=""
    local _yes=0 _update=0 _no_start=0
    local _repo="Rezishon/stalwart" _version="latest" _file=""
    _hostname=""
    _public_url=""
    _listen_smtp=25
    _listen_submission=587
    _listen_submissions=465
    _listen_imap=993
    _listen_pop3=995
    _listen_sieve=4190
    _listen_https=443
    _listen_http=8080
    _tls=true
    _dc_imap_host=""
    _dc_imap_port=""
    _dc_imap_security=ssl
    _dc_smtp_host=""
    _dc_smtp_port=""
    _dc_smtp_security=ssl
    _dc_ic=3
    _admin=

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                print_usage
                exit 0
                ;;
            -y|--yes|--non-interactive)
                _yes=1
                ;;
            -u|--update)
                _update=1
                ;;
            --no-start)
                _no_start=1
                ;;
            --tls)
                _tls=true
                ;;
            --no-tls)
                _tls=false
                ;;
            --repo)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                validate_source "$2" || err "Invalid download source: $2"
                _repo="$2"
                shift
                ;;
            --version)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                validate_version "$2" || err "Invalid version: $2"
                _version="$2"
                shift
                ;;
            --file)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                validate_source "$2" || err "Invalid download source: $2"
                _file="$2"
                shift
                ;;
            --prefix)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                validate_prefix "$2" || err "Invalid prefix: $2"
                _prefix="$2"
                shift
                ;;
            --user)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                validate_user "$2" || err "Invalid user: $2"
                _account="$2"
                shift
                ;;
            --hostname)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                if contains_cr_lf_or_quote "$2" || ! validate_hostname "$2"; then
                    err "Invalid hostname: $2"
                fi
                _hostname="$2"
                shift
                ;;
            --public-url)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                if contains_cr_lf_or_quote "$2" || ! validate_public_url "$2"; then
                    err "Invalid public URL: $2"
                fi
                _public_url="$2"
                shift
                ;;
            --admin)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                apply_admin_flag "$2"
                shift
                ;;
            --smtp-port)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                validate_port "$2" || err "Invalid port: $2"
                _listen_smtp="$2"
                shift
                ;;
            --submission-port)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                validate_port "$2" || err "Invalid port: $2"
                _listen_submission="$2"
                shift
                ;;
            --submissions-port)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                validate_port "$2" || err "Invalid port: $2"
                _listen_submissions="$2"
                shift
                ;;
            --imap-port)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                validate_port "$2" || err "Invalid port: $2"
                _listen_imap="$2"
                shift
                ;;
            --pop3-port)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                validate_port "$2" || err "Invalid port: $2"
                _listen_pop3="$2"
                shift
                ;;
            --sieve-port)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                validate_port "$2" || err "Invalid port: $2"
                _listen_sieve="$2"
                shift
                ;;
            --https-port)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                validate_port "$2" || err "Invalid port: $2"
                _listen_https="$2"
                shift
                ;;
            --http-port)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                validate_port "$2" || err "Invalid port: $2"
                _listen_http="$2"
                shift
                ;;
            --dc-imap-host)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                if contains_cr_lf_or_quote "$2" || ! validate_hostname "$2"; then
                    err "Invalid hostname: $2"
                fi
                _dc_imap_host="$2"
                shift
                ;;
            --dc-imap-port)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                validate_port "$2" || err "Invalid port: $2"
                _dc_imap_port="$2"
                shift
                ;;
            --dc-imap-security)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                validate_dc_security "$2" || err "Invalid DeltaChat security: $2"
                _dc_imap_security="$2"
                shift
                ;;
            --dc-smtp-host)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                if contains_cr_lf_or_quote "$2" || ! validate_hostname "$2"; then
                    err "Invalid hostname: $2"
                fi
                _dc_smtp_host="$2"
                shift
                ;;
            --dc-smtp-port)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                validate_port "$2" || err "Invalid port: $2"
                _dc_smtp_port="$2"
                shift
                ;;
            --dc-smtp-security)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                validate_dc_security "$2" || err "Invalid DeltaChat security: $2"
                _dc_smtp_security="$2"
                shift
                ;;
            --dc-ic)
                [ $# -ge 2 ] || err "❌ $1 requires a value"
                validate_dc_ic "$2" || err "Invalid DeltaChat ic: $2"
                _dc_ic="$2"
                shift
                ;;
            --*|-*)
                err "❌ Unknown flag: $1 (try --help)"
                ;;
            *)
                if [ -n "$_prefix" ]; then
                    err "❌ Only one prefix argument is allowed, got: $_prefix $1"
                fi
                validate_prefix "$1" || err "Invalid prefix: $1"
                _prefix="$1"
                ;;
        esac
        shift
    done

    need_cmd uname
    need_cmd hostname
    _uname="$(uname)"
    case "$_uname" in
        Linux)   _os="linux"; [ -n "$_account" ] || _account="stalwart" ;;
        FreeBSD) _os="freebsd"; [ -n "$_account" ] || _account="stalwart" ;;
        *)       err "❌ Install failed: Unsupported OS: $_uname" ;;
    esac
    [ -n "$_hostname" ] || _hostname="$(hostname -f 2>/dev/null || hostname || printf '%s\n' mail.local)"
    [ -n "$_public_url" ] || _public_url="https://${_hostname}"
    [ -n "$_dc_imap_host" ] || _dc_imap_host="$_hostname"
    [ -n "$_dc_smtp_host" ] || _dc_smtp_host="$_hostname"
    [ -n "$_dc_imap_port" ] || _dc_imap_port="$_listen_imap"
    [ -n "$_dc_smtp_port" ] || _dc_smtp_port="$_listen_submissions"

    downloader --check
    need_cmd mktemp
    need_cmd chmod
    need_cmd chown
    need_cmd mkdir
    need_cmd rm
    need_cmd tar
    need_cmd cp

    # Require root
    if [ "$(id -u)" -ne 0 ]; then
        err "❌ Install failed: This program needs to run as root."
    fi

    # Derive install paths — FHS by default, self-contained under a custom prefix
    local _bin_dir _bin_file _conf_dir _log_dir _data_dir _env_file _config_file
    if [ -z "$_prefix" ]; then
        _bin_dir="/usr/local/bin"
        _log_dir="/var/log/stalwart"
        if [ "$_os" = "freebsd" ]; then
            # hier(7): third-party config lives under /usr/local/etc,
            # variable data under /var/db
            _conf_dir="/usr/local/etc/stalwart"
            _data_dir="/var/db/stalwart"
        else
            _conf_dir="/etc/stalwart"
            _data_dir="/var/lib/stalwart"
        fi
    else
        _bin_dir="${_prefix}/bin"
        _conf_dir="${_prefix}/etc"
        _log_dir="${_prefix}/logs"
        _data_dir="${_prefix}/data"
    fi
    _bin_file="${_bin_dir}/stalwart"
    _config_file="${_conf_dir}/config.json"
    _env_file="${_conf_dir}/stalwart.env"

    # Detect architecture
    get_architecture || return 1
    local _arch="$RETVAL"
    assert_nz "$_arch" "arch"

    # Create service account
    create_account "$_os" "$_account"

    # Create directories
    ensure mkdir -p "$_bin_dir" "$_conf_dir" "$_log_dir" "$_data_dir"

    # Download and install the binary
    say "⏳ Downloading ${_component} for ${_arch}..."
    local _tmp _tar
    _tmp="$(mktemp -d)"
    _tar="${_tmp}/stalwart.tar.gz"
    ensure downloader "${BASE_URL}/${_component}-${_arch}.tar.gz" "$_tar" "$_arch"
    ensure tar zxf "$_tar" -C "$_tmp"
    ensure cp "${_tmp}/stalwart" "$_bin_file"
    ensure chmod 0755 "$_bin_file"
    ensure rm -rf "$_tmp"

    # Create env file if absent (preserve user edits on reinstall)
    if [ ! -e "$_env_file" ]; then
        say "📝 Writing env file at ${_env_file}..."
        write_env_file "$_env_file"
    fi

    # Ownership and permissions
    say "🔐 Setting permissions..."
    ensure chown "${_account}:${_account}" "$_conf_dir" "$_log_dir" "$_data_dir"
    ensure chmod 0750 "$_conf_dir" "$_log_dir" "$_data_dir"
    ensure chown "root:${_account}" "$_env_file"
    ensure chmod 0640 "$_env_file"

    # Install and start the service
    say "🚀 Starting service..."
    local _service_type=""
    case "$_os" in
        linux)
            if check_cmd systemctl; then
                create_service_linux_systemd "$_bin_file" "$_config_file" "$_env_file" "$_account"
                _service_type="systemd"
            else
                create_service_linux_initd "$_bin_file" "$_config_file" "$_env_file" "$_account"
                _service_type="initd"
            fi
            ;;
        freebsd)
            create_service_freebsd "$_bin_file" "$_config_file" "$_env_file" "$_account" "$_log_dir"
            _service_type="rcd"
            ;;
    esac

    # Completion message
    local _host
    _host="$(hostname -f 2>/dev/null || hostname)"
    say ""
    say "🎉 Installation complete!"
    say ""
    say "Stalwart is running in bootstrap mode. A temporary administrator"
    say "password was generated at startup and printed to the service logs."
    say ""
    say "👉 To find the password, inspect the service logs:"
    case "$_service_type" in
        systemd)
            say "     journalctl -u stalwart -n 200 | grep -A8 'bootstrap mode'"
            ;;
        initd)
            say "     grep -A8 'bootstrap mode' /var/log/syslog 2>/dev/null \\"
            say "       || grep -A8 'bootstrap mode' /var/log/messages"
            ;;
        rcd)
            say "     grep -A8 'bootstrap mode' ${_log_dir}/stalwart.log"
            ;;
    esac
    say ""
    say "   Or set STALWART_RECOVERY_ADMIN=admin:<password> in"
    say "   ${_env_file} and restart the service to pin a credential."
    say ""
    say "   Finish setup at: http://${_host}:8080/admin"
    say ""

    return 0
}

print_usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS] [PREFIX]

Install Stalwart into standard FHS paths or under a custom prefix.

Options:
  -y, --yes, --non-interactive  Non-interactive install using defaults
  -u, --update                  Update binary only
  --repo <repo|url>             GitHub owner/repo or https base URL
  --version <tag>               Release tag (default: latest)
  --file <path>                 Local .tar.gz archive
  --prefix <path>               Installation prefix
  --user <name>                 Service account (default: stalwart)
  --hostname <host>             STALWART_HOSTNAME
  --public-url <url>            STALWART_PUBLIC_URL
  --admin <user:pass>           Custom admin; omit for random
  --smtp-port <n>               STALWART_LISTEN_SMTP (default: 25)
  --submission-port <n>         STALWART_LISTEN_SUBMISSION (default: 587)
  --submissions-port <n>        STALWART_LISTEN_SUBMISSIONS (default: 465)
  --imap-port <n>               STALWART_LISTEN_IMAP (default: 993)
  --pop3-port <n>               STALWART_LISTEN_POP3 (default: 995)
  --sieve-port <n>              STALWART_LISTEN_SIEVE (default: 4190)
  --https-port <n>              STALWART_LISTEN_HTTPS (default: 443)
  --http-port <n>               STALWART_LISTEN_HTTP (default: 8080)
  --tls / --no-tls              STALWART_TLS=true / false (default: --tls)
  --dc-imap-host <host>         STALWART_DC_IMAP_HOST
  --dc-imap-port <n>            STALWART_DC_IMAP_PORT
  --dc-imap-security <s>        STALWART_DC_IMAP_SECURITY (default: ssl)
  --dc-smtp-host <host>         STALWART_DC_SMTP_HOST
  --dc-smtp-port <n>            STALWART_DC_SMTP_PORT
  --dc-smtp-security <s>        STALWART_DC_SMTP_SECURITY (default: ssl)
  --dc-ic <0|1|3>               STALWART_DC_IC (default: 3)
  --no-start                    Do not start or restart the service
  -h, --help                    Show this help

PREFIX may also be given as a single positional argument. If both are
given, the last --prefix wins. Extra positionals are an error.

With no PREFIX, Stalwart is installed under standard FHS paths:
  binary   /usr/local/bin/stalwart
  config   /etc/stalwart/config.json      (/usr/local/etc/stalwart/config.json on FreeBSD)
  env      /etc/stalwart/stalwart.env     (/usr/local/etc/stalwart/stalwart.env on FreeBSD)
  logs     /var/log/stalwart/
  data     /var/lib/stalwart/             (/var/db/stalwart on FreeBSD)

When PREFIX is provided, a self-contained layout is used instead:
  binary   $PREFIX/bin/stalwart
  config   $PREFIX/etc/config.json
  env      $PREFIX/etc/stalwart.env
  logs     $PREFIX/logs/
  data     $PREFIX/data/
EOF
}

emit_env() {
    printf '%s=' "$1"
    quote_env_value "$2"
}

apply_admin_flag() {
    if [ "$1" = random ]; then
        _admin=
        return 0
    fi
    if contains_cr_lf_or_quote "$1"; then
        err "Credential must be username:password or 'random'."
    fi
    case "$1" in
        *:*) ;;
        *) err "Credential must be username:password or 'random'." ;;
    esac
    _admin_user="${1%%:*}"
    _admin_pass="${1#*:}"
    if [ -z "$_admin_user" ] || ! printf '%s' "$_admin_user" | grep -Eq '^[A-Za-z0-9_-]+$'; then
        err "Username must be alphanumeric, underscore, or hyphen."
    fi
    if [ "${#_admin_pass}" -lt 12 ]; then
        err "Password must be at least 12 characters."
    fi
    _admin="$1"
}

write_env_file() {
    {
        printf '%s\n' '# Environment variables for the Stalwart service.'
        printf '%s\n' '# Uncomment and edit an entry to override its default.'
        printf '\n'
        printf '%s\n' '# Override the hostname used in HTTP responses'
        emit_env STALWART_HOSTNAME "$_hostname" || return 1
        printf '\n'
        printf '%s\n' '# Override the public base URL published in OAuth, OIDC, and JMAP discovery'
        printf '%s\n' '# documents. Accepts scheme, host, optional port, and optional path prefix.'
        emit_env STALWART_PUBLIC_URL "$_public_url" || return 1
        printf '\n'
        printf '%s\n' '# First-boot listeners. Port 0 skips that listener.'
        emit_env STALWART_LISTEN_SMTP "$_listen_smtp" || return 1
        emit_env STALWART_LISTEN_SUBMISSION "$_listen_submission" || return 1
        emit_env STALWART_LISTEN_SUBMISSIONS "$_listen_submissions" || return 1
        emit_env STALWART_LISTEN_IMAP "$_listen_imap" || return 1
        emit_env STALWART_LISTEN_POP3 "$_listen_pop3" || return 1
        emit_env STALWART_LISTEN_SIEVE "$_listen_sieve" || return 1
        emit_env STALWART_LISTEN_HTTPS "$_listen_https" || return 1
        emit_env STALWART_LISTEN_HTTP "$_listen_http" || return 1
        printf '\n'
        printf '%s\n' '# TLS on inserted listeners (1/true/0/false).'
        emit_env STALWART_TLS "$_tls" || return 1
        printf '\n'
        printf '%s\n' '# DeltaChat advertised endpoints (first insert only).'
        emit_env STALWART_DC_IMAP_HOST "$_dc_imap_host" || return 1
        emit_env STALWART_DC_IMAP_PORT "$_dc_imap_port" || return 1
        emit_env STALWART_DC_IMAP_SECURITY "$_dc_imap_security" || return 1
        emit_env STALWART_DC_SMTP_HOST "$_dc_smtp_host" || return 1
        emit_env STALWART_DC_SMTP_PORT "$_dc_smtp_port" || return 1
        emit_env STALWART_DC_SMTP_SECURITY "$_dc_smtp_security" || return 1
        emit_env STALWART_DC_IC "$_dc_ic" || return 1
        if [ -n "${_admin:-}" ] && [ "$_admin" != random ]; then
            printf '\n'
            printf '%s\n' '# Fixed administrator credentials — format: username:password'
            emit_env STALWART_RECOVERY_ADMIN "$_admin" || return 1
        fi
        printf '\n'
        printf '%s\n' '# Cluster role assigned to this node. Must match a role name defined in the'
        printf '%s\n' '# cluster registry. Leave unset for a standalone (non-clustered) deployment.'
        printf '%s\n' '#STALWART_ROLE=primary'
        printf '\n'
        printf '%s\n' '# Push-notification shard this node is responsible for, when running in a'
        printf '%s\n' '# cluster.'
        printf '%s\n' '#STALWART_PUSH_SHARD=1'
    } > "$1"
}

create_account() {
    local _os="$1"
    local _account="$2"
    if id -u "$_account" > /dev/null 2>&1; then
        return 0
    fi
    say "🖥️  Creating '${_account}' account..."
    if [ "$_os" = "freebsd" ]; then
        ensure pw useradd -n "$_account" -c "Stalwart service" -d /nonexistent -s /usr/sbin/nologin -w no
    else
        ensure useradd "$_account" -s /usr/sbin/nologin -M -r -U
    fi
}

create_service_linux_systemd() {
    local _bin="$1" _config="$2" _env="$3" _user="$4"
    cat > /etc/systemd/system/stalwart.service <<EOF
[Unit]
Description=Stalwart
Conflicts=postfix.service sendmail.service exim4.service
After=network-online.target

[Service]
Type=simple
LimitNOFILE=65536
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
EnvironmentFile=-${_env}
ExecStart=${_bin} --config=${_config}
SyslogIdentifier=stalwart
User=${_user}
Group=${_user}
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable stalwart.service
    systemctl restart stalwart.service
}

create_service_linux_initd() {
    local _bin="$1" _config="$2" _env="$3" _user="$4"
    cat > /etc/init.d/stalwart <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          stalwart
# Required-Start:    \$network
# Required-Stop:     \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Stalwart Server
# Description:       Starts and stops the Stalwart Server
# Conflicts:         postfix sendmail
### END INIT INFO

PATH=/sbin:/usr/sbin:/bin:/usr/bin

. /lib/init/vars.sh
. /lib/lsb/init-functions

DAEMON=${_bin}
DAEMON_ARGS="--config=${_config}"
ENV_FILE=${_env}
PIDFILE=/var/run/stalwart.pid
ULIMIT_NOFILE=65536

[ -x "\$DAEMON" ] || exit 0

if [ -r "\$ENV_FILE" ]; then
    set -a
    . "\$ENV_FILE"
    set +a
fi

ulimit -n \$ULIMIT_NOFILE

do_start()
{
    start-stop-daemon --start --quiet --pidfile \$PIDFILE --exec \$DAEMON --test > /dev/null \\
        || return 1
    start-stop-daemon --start --quiet --pidfile \$PIDFILE --exec \$DAEMON \\
        --background --make-pidfile --chuid ${_user}:${_user} \\
        -- \$DAEMON_ARGS \\
        || return 2
}

do_stop()
{
    start-stop-daemon --stop --quiet --retry=INT/30/KILL/5 --pidfile \$PIDFILE --name stalwart
    RETVAL="\$?"
    [ "\$RETVAL" = 2 ] && return 2
    start-stop-daemon --stop --quiet --oknodo --retry=0/30/KILL/5 --exec \$DAEMON
    [ "\$?" = 2 ] && return 2
    rm -f \$PIDFILE
    return "\$RETVAL"
}

case "\$1" in
  start)
    [ "\$VERBOSE" != no ] && log_daemon_msg "Starting Stalwart Server" "stalwart"
    do_start
    case "\$?" in
        0|1) [ "\$VERBOSE" != no ] && log_end_msg 0 ;;
        2)   [ "\$VERBOSE" != no ] && log_end_msg 1 ;;
    esac
    ;;
  stop)
    [ "\$VERBOSE" != no ] && log_daemon_msg "Stopping Stalwart Server" "stalwart"
    do_stop
    case "\$?" in
        0|1) [ "\$VERBOSE" != no ] && log_end_msg 0 ;;
        2)   [ "\$VERBOSE" != no ] && log_end_msg 1 ;;
    esac
    ;;
  status)
    status_of_proc "\$DAEMON" "stalwart" && exit 0 || exit \$?
    ;;
  restart)
    log_daemon_msg "Restarting Stalwart Server" "stalwart"
    do_stop
    case "\$?" in
      0|1)
        do_start
        case "\$?" in
            0) log_end_msg 0 ;;
            *) log_end_msg 1 ;;
        esac
        ;;
      *)
        log_end_msg 1
        ;;
    esac
    ;;
  *)
    echo "Usage: /etc/init.d/stalwart {start|stop|status|restart}" >&2
    exit 3
    ;;
esac

exit 0
EOF
    chmod +x /etc/init.d/stalwart
    update-rc.d stalwart defaults
    service stalwart start
}

create_service_freebsd() {
    local _bin="$1" _config="$2" _env="$3" _user="$4" _log_dir="$5"
    ensure mkdir -p /usr/local/etc/rc.d
    cat > /usr/local/etc/rc.d/stalwart <<EOF
#!/bin/sh

# PROVIDE: stalwart
# REQUIRE: NETWORKING LOGIN
# KEYWORD: shutdown

. /etc/rc.subr

name="stalwart"
rcvar="stalwart_enable"
desc="Stalwart Server"

load_rc_config \$name

: \${stalwart_enable:="NO"}
: \${stalwart_runas_user:="${_user}"}
: \${stalwart_runas_group:="${_user}"}
: \${stalwart_config:="${_config}"}
: \${stalwart_envfile:="${_env}"}
: \${stalwart_logfile:="${_log_dir}/stalwart.log"}
: \${stalwart_fdlimit:="65536"}

pidfile="/var/run/stalwart.pid"
procname="${_bin}"
command="/usr/sbin/daemon"
command_args="-f -o \${stalwart_logfile} -p \${pidfile} ${_bin} --config=\${stalwart_config}"
sig_stop="INT"
start_precmd="stalwart_precmd"

stalwart_precmd()
{
    # daemon(8) passes its environment through to the service
    if [ -r "\${stalwart_envfile}" ]; then
        set -a
        . "\${stalwart_envfile}"
        set +a
    fi

    # Stalwart binds its listeners as root, then setuid()s to this account
    export RUN_AS_USER="\${stalwart_runas_user}"
    export RUN_AS_GROUP="\${stalwart_runas_group}"

    ulimit -n "\${stalwart_fdlimit}"
}

run_rc_command "\$1"
EOF
    chmod +x /usr/local/etc/rc.d/stalwart
    sysrc stalwart_enable=YES
    service stalwart stop > /dev/null 2>&1 || true
    service stalwart start
}


get_architecture() {
    local _ostype _cputype _bitness _arch _clibtype
    _ostype="$(uname -s)"
    _cputype="$(uname -m)"
    _clibtype="gnu"

    if [ "$_ostype" = Linux ]; then
        if [ "$(uname -o)" = Android ]; then
            _ostype=Android
        fi
        if ldd --version 2>&1 | grep -q 'musl'; then
            _clibtype="musl"
        fi
    fi

    if [ "$_ostype" = Darwin ] && [ "$_cputype" = i386 ]; then
        # Darwin `uname -m` lies
        if sysctl hw.optional.x86_64 | grep -q ': 1'; then
            _cputype=x86_64
        fi
    fi

    if [ "$_ostype" = SunOS ]; then
        # Both Solaris and illumos presently announce as "SunOS" in "uname -s"
        # so use "uname -o" to disambiguate.  We use the full path to the
        # system uname in case the user has coreutils uname first in PATH,
        # which has historically sometimes printed the wrong value here.
        if [ "$(/usr/bin/uname -o)" = illumos ]; then
            _ostype=illumos
        fi

        # illumos systems have multi-arch userlands, and "uname -m" reports the
        # machine hardware name; e.g., "i86pc" on both 32- and 64-bit x86
        # systems.  Check for the native (widest) instruction set on the
        # running kernel:
        if [ "$_cputype" = i86pc ]; then
            _cputype="$(isainfo -n)"
        fi
    fi

    case "$_ostype" in

        Android)
            _ostype=linux-android
            ;;

        Linux)
            check_proc
            _ostype=unknown-linux-$_clibtype
            _bitness=$(get_bitness)
            ;;

        FreeBSD)
            _ostype=unknown-freebsd
            ;;

        NetBSD)
            _ostype=unknown-netbsd
            ;;

        DragonFly)
            _ostype=unknown-dragonfly
            ;;

        Darwin)
            _ostype=apple-darwin
            ;;

        illumos)
            _ostype=unknown-illumos
            ;;

        MINGW* | MSYS* | CYGWIN* | Windows_NT)
            _ostype=pc-windows-gnu
            ;;

        *)
            err "unrecognized OS type: $_ostype"
            ;;

    esac

    case "$_cputype" in

        i386 | i486 | i686 | i786 | x86)
            _cputype=i686
            ;;

        xscale | arm)
            _cputype=arm
            if [ "$_ostype" = "linux-android" ]; then
                _ostype=linux-androideabi
            fi
            ;;

        armv6l)
            _cputype=arm
            if [ "$_ostype" = "linux-android" ]; then
                _ostype=linux-androideabi
            else
                _ostype="${_ostype}eabihf"
            fi
            ;;

        armv7l | armv8l)
            _cputype=armv7
            if [ "$_ostype" = "linux-android" ]; then
                _ostype=linux-androideabi
            else
                _ostype="${_ostype}eabihf"
            fi
            ;;

        aarch64 | arm64)
            _cputype=aarch64
            ;;

        x86_64 | x86-64 | x64 | amd64)
            _cputype=x86_64
            ;;

        mips)
            _cputype=$(get_endianness mips '' el)
            ;;

        mips64)
            if [ "$_bitness" -eq 64 ]; then
                # only n64 ABI is supported for now
                _ostype="${_ostype}abi64"
                _cputype=$(get_endianness mips64 '' el)
            fi
            ;;

        ppc)
            _cputype=powerpc
            ;;

        ppc64)
            _cputype=powerpc64
            ;;

        ppc64le)
            _cputype=powerpc64le
            ;;

        s390x)
            _cputype=s390x
            ;;
        riscv64)
            _cputype=riscv64gc
            ;;
        *)
            err "unknown CPU type: $_cputype"

    esac

    # Detect 64-bit linux with 32-bit userland
    if [ "${_ostype}" = unknown-linux-gnu ] && [ "${_bitness}" -eq 32 ]; then
        case $_cputype in
            x86_64)
                if [ -n "${RUSTUP_CPUTYPE:-}" ]; then
                    _cputype="$RUSTUP_CPUTYPE"
                else {
                    # 32-bit executable for amd64 = x32
                    if is_host_amd64_elf; then {
                         echo "This host is running an x32 userland; as it stands, x32 support is poor," 1>&2
                         echo "and there isn't a native toolchain -- you will have to install" 1>&2
                         echo "multiarch compatibility with i686 and/or amd64, then select one" 1>&2
                         echo "by re-running this script with the RUSTUP_CPUTYPE environment variable" 1>&2
                         echo "set to i686 or x86_64, respectively." 1>&2
                         echo 1>&2
                         echo "You will be able to add an x32 target after installation by running" 1>&2
                         echo "  rustup target add x86_64-unknown-linux-gnux32" 1>&2
                         exit 1
                    }; else
                        _cputype=i686
                    fi
                }; fi
                ;;
            mips64)
                _cputype=$(get_endianness mips '' el)
                ;;
            powerpc64)
                _cputype=powerpc
                ;;
            aarch64)
                _cputype=armv7
                if [ "$_ostype" = "linux-android" ]; then
                    _ostype=linux-androideabi
                else
                    _ostype="${_ostype}eabihf"
                fi
                ;;
            riscv64gc)
                err "riscv64 with 32-bit userland unsupported"
                ;;
        esac
    fi

    # Detect armv7 but without the CPU features Rust needs in that build,
    # and fall back to arm.
    # See https://github.com/rust-lang/rustup.rs/issues/587.
    if [ "$_ostype" = "unknown-linux-gnueabihf" ] && [ "$_cputype" = armv7 ]; then
        if ensure grep '^Features' /proc/cpuinfo | grep -q -v neon; then
            # At least one processor does not have NEON.
            _cputype=arm
        fi
    fi

    _arch="${_cputype}-${_ostype}"

    RETVAL="$_arch"
}

check_proc() {
    # Check for /proc by looking for the /proc/self/exe link
    # This is only run on Linux
    if ! test -L /proc/self/exe ; then
        err "fatal: Unable to find /proc/self/exe.  Is /proc mounted?  Installation cannot proceed without /proc."
    fi
}

get_bitness() {
    need_cmd head
    # Architecture detection without dependencies beyond coreutils.
    # ELF files start out "\x7fELF", and the following byte is
    #   0x01 for 32-bit and
    #   0x02 for 64-bit.
    # The printf builtin on some shells like dash only supports octal
    # escape sequences, so we use those.
    local _current_exe_head
    _current_exe_head=$(head -c 5 /proc/self/exe )
    if [ "$_current_exe_head" = "$(printf '\177ELF\001')" ]; then
        echo 32
    elif [ "$_current_exe_head" = "$(printf '\177ELF\002')" ]; then
        echo 64
    else
        err "unknown platform bitness"
    fi
}

is_host_amd64_elf() {
    need_cmd head
    need_cmd tail
    # ELF e_machine detection without dependencies beyond coreutils.
    # Two-byte field at offset 0x12 indicates the CPU,
    # but we're interested in it being 0x3E to indicate amd64, or not that.
    local _current_exe_machine
    _current_exe_machine=$(head -c 19 /proc/self/exe | tail -c 1)
    [ "$_current_exe_machine" = "$(printf '\076')" ]
}

get_endianness() {
    local cputype=$1
    local suffix_eb=$2
    local suffix_el=$3

    # detect endianness without od/hexdump, like get_bitness() does.
    need_cmd head
    need_cmd tail

    local _current_exe_endianness
    _current_exe_endianness="$(head -c 6 /proc/self/exe | tail -c 1)"
    if [ "$_current_exe_endianness" = "$(printf '\001')" ]; then
        echo "${cputype}${suffix_el}"
    elif [ "$_current_exe_endianness" = "$(printf '\002')" ]; then
        echo "${cputype}${suffix_eb}"
    else
        err "unknown platform endianness"
    fi
}

say() {
    printf '%s\n' "$1"
}

err() {
    say "$1" >&2
    exit 1
}

need_cmd() {
    if ! check_cmd "$1"; then
        err "need '$1' (command not found)"
    fi
}

check_cmd() {
    command -v "$1" > /dev/null 2>&1
}

assert_nz() {
    if [ -z "$1" ]; then err "assert_nz $2"; fi
}

# Run a command that should never fail. If the command fails execution
# will immediately terminate with an error showing the failing
# command.
ensure() {
    if ! "$@"; then err "command failed: $*"; fi
}

# This wraps curl or wget. Try curl first, if not installed,
# use wget instead.
downloader() {
    local _dld
    local _ciphersuites
    local _err
    local _status
    local _retry
    if check_cmd curl; then
        _dld=curl
    elif check_cmd wget; then
        _dld=wget
    else
        _dld='curl or wget' # to be used in error message of need_cmd
    fi

    if [ "$1" = --check ]; then
        need_cmd "$_dld"
    elif [ "$_dld" = curl ]; then
        check_curl_for_retry_support
        _retry="$RETVAL"
        get_ciphersuites_for_curl
        _ciphersuites="$RETVAL"
        if [ -n "$_ciphersuites" ]; then
            _err=$(curl $_retry --proto '=https' --tlsv1.2 --ciphers "$_ciphersuites" --silent --show-error --fail --location "$1" --output "$2" 2>&1)
            _status=$?
        else
            echo "Warning: Not enforcing strong cipher suites for TLS, this is potentially less secure"
            if ! check_help_for "$3" curl --proto --tlsv1.2; then
                echo "Warning: Not enforcing TLS v1.2, this is potentially less secure"
                _err=$(curl $_retry --silent --show-error --fail --location "$1" --output "$2" 2>&1)
                _status=$?
            else
                _err=$(curl $_retry --proto '=https' --tlsv1.2 --silent --show-error --fail --location "$1" --output "$2" 2>&1)
                _status=$?
            fi
        fi
        if [ -n "$_err" ]; then
            if echo "$_err" | grep -q 404; then
                err "❌  Binary for platform '$3' not found, this platform may be unsupported."
            else
                echo "$_err" >&2
            fi
        fi
        return $_status
    elif [ "$_dld" = wget ]; then
        if [ "$(wget -V 2>&1|head -2|tail -1|cut -f1 -d" ")" = "BusyBox" ]; then
            echo "Warning: using the BusyBox version of wget.  Not enforcing strong cipher suites for TLS or TLS v1.2, this is potentially less secure"
            _err=$(wget "$1" -O "$2" 2>&1)
            _status=$?
        else
            get_ciphersuites_for_wget
            _ciphersuites="$RETVAL"
            if [ -n "$_ciphersuites" ]; then
                _err=$(wget --https-only --secure-protocol=TLSv1_2 --ciphers "$_ciphersuites" "$1" -O "$2" 2>&1)
                _status=$?
            else
                echo "Warning: Not enforcing strong cipher suites for TLS, this is potentially less secure"
                if ! check_help_for "$3" wget --https-only --secure-protocol; then
                    echo "Warning: Not enforcing TLS v1.2, this is potentially less secure"
                    _err=$(wget "$1" -O "$2" 2>&1)
                    _status=$?
                else
                    _err=$(wget --https-only --secure-protocol=TLSv1_2 "$1" -O "$2" 2>&1)
                    _status=$?
                fi
            fi
        fi
        if [ -n "$_err" ]; then
            if echo "$_err" | grep -q ' 404 Not Found'; then
                err "❌  Binary for platform '$3' not found, this platform may be unsupported."
            else
                echo "$_err" >&2
            fi
        fi
        return $_status
    else
        err "Unknown downloader"   # should not reach here
    fi
}

# Check if curl supports the --retry flag, then pass it to the curl invocation.
check_curl_for_retry_support() {
  local _retry_supported=""
  # "unspecified" is for arch, allows for possibility old OS using macports, homebrew, etc.
  if check_help_for "notspecified" "curl" "--retry"; then
    _retry_supported="--retry 3"
  fi

  RETVAL="$_retry_supported"

}

check_help_for() {
    local _arch
    local _cmd
    local _arg
    _arch="$1"
    shift
    _cmd="$1"
    shift

    local _category
    if "$_cmd" --help | grep -q 'For all options use the manual or "--help all".'; then
      _category="all"
    else
      _category=""
    fi

    case "$_arch" in

        *darwin*)
        if check_cmd sw_vers; then
            case $(sw_vers -productVersion) in
                10.*)
                    # If we're running on macOS, older than 10.13, then we always
                    # fail to find these options to force fallback
                    if [ "$(sw_vers -productVersion | cut -d. -f2)" -lt 13 ]; then
                        # Older than 10.13
                        echo "Warning: Detected macOS platform older than 10.13"
                        return 1
                    fi
                    ;;
                11.*)
                    # We assume Big Sur will be OK for now
                    ;;
                *)
                    # Unknown product version, warn and continue
                    echo "Warning: Detected unknown macOS major version: $(sw_vers -productVersion)"
                    echo "Warning TLS capabilities detection may fail"
                    ;;
            esac
        fi
        ;;

    esac

    for _arg in "$@"; do
        if ! "$_cmd" --help $_category | grep -q -- "$_arg"; then
            return 1
        fi
    done

    true # not strictly needed
}

# Return cipher suite string specified by user, otherwise return strong TLS 1.2-1.3 cipher suites
# if support by local tools is detected. Detection currently supports these curl backends:
# GnuTLS and OpenSSL (possibly also LibreSSL and BoringSSL). Return value can be empty.
get_ciphersuites_for_curl() {
    if [ -n "${RUSTUP_TLS_CIPHERSUITES-}" ]; then
        # user specified custom cipher suites, assume they know what they're doing
        RETVAL="$RUSTUP_TLS_CIPHERSUITES"
        return
    fi

    local _openssl_syntax="no"
    local _gnutls_syntax="no"
    local _backend_supported="yes"
    if curl -V | grep -q ' OpenSSL/'; then
        _openssl_syntax="yes"
    elif curl -V | grep -iq ' LibreSSL/'; then
        _openssl_syntax="yes"
    elif curl -V | grep -iq ' BoringSSL/'; then
        _openssl_syntax="yes"
    elif curl -V | grep -iq ' GnuTLS/'; then
        _gnutls_syntax="yes"
    else
        _backend_supported="no"
    fi

    local _args_supported="no"
    if [ "$_backend_supported" = "yes" ]; then
        # "unspecified" is for arch, allows for possibility old OS using macports, homebrew, etc.
        if check_help_for "notspecified" "curl" "--tlsv1.2" "--ciphers" "--proto"; then
            _args_supported="yes"
        fi
    fi

    local _cs=""
    if [ "$_args_supported" = "yes" ]; then
        if [ "$_openssl_syntax" = "yes" ]; then
            _cs=$(get_strong_ciphersuites_for "openssl")
        elif [ "$_gnutls_syntax" = "yes" ]; then
            _cs=$(get_strong_ciphersuites_for "gnutls")
        fi
    fi

    RETVAL="$_cs"
}

# Return cipher suite string specified by user, otherwise return strong TLS 1.2-1.3 cipher suites
# if support by local tools is detected. Detection currently supports these wget backends:
# GnuTLS and OpenSSL (possibly also LibreSSL and BoringSSL). Return value can be empty.
get_ciphersuites_for_wget() {
    if [ -n "${RUSTUP_TLS_CIPHERSUITES-}" ]; then
        # user specified custom cipher suites, assume they know what they're doing
        RETVAL="$RUSTUP_TLS_CIPHERSUITES"
        return
    fi

    local _cs=""
    if wget -V | grep -q '\-DHAVE_LIBSSL'; then
        # "unspecified" is for arch, allows for possibility old OS using macports, homebrew, etc.
        if check_help_for "notspecified" "wget" "TLSv1_2" "--ciphers" "--https-only" "--secure-protocol"; then
            _cs=$(get_strong_ciphersuites_for "openssl")
        fi
    elif wget -V | grep -q '\-DHAVE_LIBGNUTLS'; then
        # "unspecified" is for arch, allows for possibility old OS using macports, homebrew, etc.
        if check_help_for "notspecified" "wget" "TLSv1_2" "--ciphers" "--https-only" "--secure-protocol"; then
            _cs=$(get_strong_ciphersuites_for "gnutls")
        fi
    fi

    RETVAL="$_cs"
}

# Return strong TLS 1.2-1.3 cipher suites in OpenSSL or GnuTLS syntax. TLS 1.2
# excludes non-ECDHE and non-AEAD cipher suites. DHE is excluded due to bad
# DH params often found on servers (see RFC 7919). Sequence matches or is
# similar to Firefox 68 ESR with weak cipher suites disabled via about:config.
# $1 must be openssl or gnutls.
get_strong_ciphersuites_for() {
    if [ "$1" = "openssl" ]; then
        # OpenSSL is forgiving of unknown values, no problems with TLS 1.3 values on versions that don't support it yet.
        echo "TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384"
    elif [ "$1" = "gnutls" ]; then
        # GnuTLS isn't forgiving of unknown values, so this may require a GnuTLS version that supports TLS 1.3 even if wget doesn't.
        # Begin with SECURE128 (and higher) then remove/add to build cipher suites. Produces same 9 cipher suites as OpenSSL but in slightly different order.
        echo "SECURE128:-VERS-SSL3.0:-VERS-TLS1.0:-VERS-TLS1.1:-VERS-DTLS-ALL:-CIPHER-ALL:-MAC-ALL:-KX-ALL:+AEAD:+ECDHE-ECDSA:+ECDHE-RSA:+AES-128-GCM:+CHACHA20-POLY1305:+AES-256-GCM"
    fi
}

# This is just for indicating that commands' results are being
# intentionally ignored. Usually, because it's being executed
# as part of error handling.
ignore() {
    "$@"
}

if [ -z "${INSTALL_TEST:-}" ]; then
    main "$@" || exit 1
fi
