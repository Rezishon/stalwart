#!/usr/bin/env sh
# shellcheck shell=dash

#
# SPDX-FileCopyrightText: 2020 Stalwart Labs LLC <hello@stalw.art>
#
# SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
#

# MailiaM install script -- based on the rustup installation script.

set -e
set -u

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

validate_email() {
    [ -n "$1" ] || return 1
    contains_cr_lf_or_quote "$1" && return 1
    case "$1" in
        *@*.*) return 0 ;;
        *) return 1 ;;
    esac
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
            printf '%s\n' "${_src%/}/mailiam-${_target}.tar.gz"
            ;;
        *)
            if [ "$_tag" = latest ]; then
                printf '%s\n' "https://github.com/${_src}/releases/latest/download/mailiam-${_target}.tar.gz"
            else
                printf '%s\n' "https://github.com/${_src}/releases/download/${_tag}/mailiam-${_target}.tar.gz"
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
        _log_dir=/var/log/mailiam
        if [ "$_os" = freebsd ]; then
            _conf_dir=/usr/local/etc/mailiam
            _data_dir=/var/db/mailiam
        else
            _conf_dir=/etc/mailiam
            _data_dir=/var/lib/mailiam
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
    _ue_file="$1"
    _ue_key="$2"
    _ue_value="$3"
    if ! quote_env_value "$_ue_value" >/dev/null; then
        return 1
    fi
    _out=$(mktemp)
    _found=0
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            "${_ue_key}="*|"#${_ue_key}="*)
                printf '%s=%s\n' "$_ue_key" "'$_ue_value'"
                _found=1
                ;;
            *)
                printf '%s\n' "$_line"
                ;;
        esac
    done < "$_ue_file" > "$_out"
    if [ "$_found" -eq 0 ]; then
        printf '%s=%s\n' "$_ue_key" "'$_ue_value'" >> "$_out"
    fi
    cat "$_out" > "$_ue_file"
    rm -f "$_out"
}

prompt_read() {
    printf '%s' "$1"
    _prompt_ans=
    read -r _prompt_ans || _prompt_ans=
}

prompt_value() {
    _pv_var="$1"
    _pv_def="$2"
    _pv_fn="$3"
    _pv_err="$4"
    _pv_label="$5"
    while :; do
        prompt_read "$(fmt_prompt "$_pv_label" "$_pv_def")"
        [ -n "$_prompt_ans" ] || _prompt_ans="$_pv_def"
        if "$_pv_fn" "$_prompt_ans"; then
            eval "$_pv_var=\"\$_prompt_ans\""
            return 0
        fi
        printf '%s\n' "$_pv_err"
    done
}

prompt_port() {
    _pp_var="$1"
    _pp_def="$2"
    _pp_label="$3"
    _pp_nodup="${4:-}"
    while :; do
        prompt_read "$(fmt_prompt "$_pp_label" "$_pp_def")"
        [ -n "$_prompt_ans" ] || _prompt_ans="$_pp_def"
        if ! validate_port "$_prompt_ans"; then
            printf '%s\n' "Port must be an integer 0-65535."
            continue
        fi
        if [ -z "$_pp_nodup" ] && [ "$_prompt_ans" != 0 ]; then
            case " ${_used_ports} " in
                *" ${_prompt_ans} "*)
                    printf '%s\n' "Port already used."
                    continue
                    ;;
            esac
            _used_ports="${_used_ports} ${_prompt_ans}"
        fi
        eval "$_pp_var=\"\$_prompt_ans\""
        return 0
    done
}

prompt_yes_no() {
    _pyn_var="$1"
    _pyn_def="$2"
    _pyn_label="$3"
    while :; do
        prompt_read "$(fmt_prompt "$_pyn_label" "$_pyn_def")"
        [ -n "$_prompt_ans" ] || _prompt_ans="$_pyn_def"
        if validate_yes_no "$_prompt_ans"; then
            eval "$_pyn_var=\"\$_prompt_ans\""
            return 0
        fi
        printf '%s\n' "Enter y or n."
    done
}

is_yes() {
    case "$1" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

generate_password() {
    od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
}

ensure_generated_admin() {
    if [ -n "${_admin:-}" ] && [ "$_admin" != random ]; then
        return 0
    fi
    _gp=$(generate_password)
    [ "${#_gp}" -eq 16 ] || err "Failed to generate admin password."
    _admin="admin:${_gp}"
}

CLR_RED=
CLR_BOLD=
CLR_BLUE=
CLR_DIM=
CLR_ITALIC=
CLR_HINT=
CLR_URL=
CLR_GREEN=
CLR_RESET=

init_colors() {
    if [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = dumb ] || [ ! -t 1 ]; then
        CLR_RED=
        CLR_BOLD=
        CLR_BLUE=
        CLR_DIM=
        CLR_ITALIC=
        CLR_HINT=
        CLR_URL=
        CLR_GREEN=
        CLR_RESET=
        return 0
    fi
    CLR_RED=$(printf '\033[1;31m')
    CLR_BOLD=$(printf '\033[1m')
    CLR_BLUE=$(printf '\033[94m')
    CLR_DIM=$(printf '\033[2m')
    CLR_ITALIC=$(printf '\033[3m')
    CLR_HINT=$(printf '\033[2;3m')
    CLR_URL=$(printf '\033[1;94m')
    CLR_GREEN=$(printf '\033[1;32m')
    CLR_RESET=$(printf '\033[0m')
}

fmt_prompt() {
    printf '%s%s%s %s(Default: %s)%s: ' \
        "$CLR_BOLD" "$1" "$CLR_RESET" "$CLR_HINT" "$2" "$CLR_RESET"
}

clear_step() {
    if [ -t 0 ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
        printf '\033[H\033[2J'
        print_banner
    fi
}

say_header() {
    printf '%s%s%s\n' "$CLR_BOLD" "$1" "$CLR_RESET"
}

say_hint() {
    printf '%s%s%s\n' "$CLR_HINT" "$1" "$CLR_RESET"
}

say_opt() {
    if [ -n "${3:-}" ]; then
        printf '  %s%s)%s %s %s(%s)%s\n' \
            "$CLR_BLUE" "$1" "$CLR_RESET" "$2" "$CLR_HINT" "$3" "$CLR_RESET"
    else
        printf '  %s%s)%s %s\n' "$CLR_BLUE" "$1" "$CLR_RESET" "$2"
    fi
}

print_hr() {
    printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' \
        "$CLR_DIM" "$CLR_RESET"
}

hostname_default() {
    case "$1" in
        *.*) printf '%s\n' "$1" ;;
        *) printf '%s\n' mail.localhost ;;
    esac
}

tag_from_release_url() {
    case "$1" in
        */releases/tag/*) printf '%s\n' "${1##*/}" ;;
        *) printf '%s\n' latest ;;
    esac
}

prompt_choice() {
    _pc_var="$1"
    _pc_def="$2"
    _pc_max="$3"
    _pc_label="$4"
    while :; do
        prompt_read "$(fmt_prompt "$_pc_label" "$_pc_def")"
        [ -n "$_prompt_ans" ] || _prompt_ans="$_pc_def"
        case "$_prompt_ans" in
            *[!0-9]*|'') ;;
            *)
                if [ "$_prompt_ans" -ge 1 ] && [ "$_prompt_ans" -le "$_pc_max" ]; then
                    eval "$_pc_var=\"\$_prompt_ans\""
                    return 0
                fi
                ;;
        esac
        printf 'Choose 1-%s.\n' "$_pc_max"
    done
}

prompt_admin() {
    _pa_keep=0
    [ "${1:-}" = keep ] && _pa_keep=1
    clear_step
    say_header "Admin WebUI credentials:"
    say_hint "Initial administrator account for the web management console (/admin)."
    say ""
    say_header "Select admin setup:"
    if [ "$_pa_keep" -eq 1 ]; then
        say_opt 1 "Keep existing admin password" "Default"
        say_opt 2 "Set custom username and password"
    else
        say_opt 1 "Auto-generate secure password" "Default: user 'admin'"
        say_opt 2 "Set custom username and password"
    fi
    prompt_choice _pa_choice 1 2 "Choice [1-2]"
    if [ "$_pa_choice" = 1 ]; then
        if [ "$_pa_keep" -eq 1 ]; then
            _admin=
        else
            ensure_generated_admin
        fi
        return 0
    fi
    clear_step
    prompt_value _admin_user admin validate_user "Invalid username." "Admin username"
    clear_step
    while :; do
        prompt_read "${CLR_BOLD}Admin password${CLR_RESET}: "
        if contains_cr_lf_or_quote "$_prompt_ans"; then
            printf '%s\n' "Password must not contain quotes or newlines."
            continue
        fi
        if [ "${#_prompt_ans}" -lt 12 ]; then
            printf '%s\n' "Password must be at least 12 characters."
            continue
        fi
        _admin="${_admin_user}:${_prompt_ans}"
        return 0
    done
}

detect_installed_bin() {
    if [ -e "${_bin_dir}/mailiam" ]; then
        printf '%s\n' "${_bin_dir}/mailiam"
        return 0
    fi
    if [ -e "${_bin_dir}/stalwart" ]; then
        printf '%s\n' "${_bin_dir}/stalwart"
        return 0
    fi
    [ "$_bin_dir" = /usr/local/bin ] || return 1
    _p=$(command -v mailiam 2>/dev/null) || _p=
    if [ -n "$_p" ] && [ -e "$_p" ]; then
        printf '%s\n' "$_p"
        return 0
    fi
    _p=$(command -v stalwart 2>/dev/null) || _p=
    if [ -n "$_p" ] && [ -e "$_p" ]; then
        printf '%s\n' "$_p"
        return 0
    fi
    return 1
}

installed_version() {
    if [ -x "$1" ]; then
        "$1" --version 2>/dev/null | awk '{print $NF; exit}'
    fi
}

latest_release_tag() {
    _lr_url=$(curl -sIL -o /dev/null -w '%{url_effective}\n' \
        "https://github.com/${1}/releases/latest" 2>/dev/null) || _lr_url=
    [ -n "$_lr_url" ] || { printf '%s\n' latest; return 0; }
    tag_from_release_url "$_lr_url"
}

prompt_mode() {
    _pm_bin="${1:-$_bin_file}"
    _pm_ver="$(installed_version "$_pm_bin")"
    _pm_latest="$(latest_release_tag "${_repo:-Rezishon/stalwart}")"
    clear_step
    say_header "Current installation detected:"
    printf '  - Binary:   %s' "$_pm_bin"
    if [ -n "$_pm_ver" ]; then
        printf ' %s(version %s)%s' "$CLR_HINT" "$_pm_ver" "$CLR_RESET"
    fi
    printf '\n'
    printf '  - Config:   %s\n' "$_conf_dir"
    printf '  - Database: %s\n' "$_data_dir"
    if [ -n "$_pm_latest" ] && [ "$_pm_latest" != latest ] && [ -n "$_pm_ver" ] \
        && [ "$_pm_latest" != "$_pm_ver" ] && [ "$_pm_latest" != "v${_pm_ver}" ]; then
        printf '  - Status:   %sUpdate available: %s%s\n' "$CLR_URL" "$_pm_latest" "$CLR_RESET"
        _pm_opt1="Update binary to ${_pm_latest}"
    else
        printf '  - Status:   You are currently running the latest version.\n'
        _pm_opt1="Update binary"
        _pm_latest=latest
    fi
    say ""
    say_header "Select action:"
    say_opt 1 "$_pm_opt1" "Default - keeps config & mail data safe"
    say_opt 2 "Reconfigure server settings" "Update domain, ports, TLS, or admin"
    say_opt 3 "Fresh reinstall" "Clean install - resets configuration"
    prompt_choice _install_mode 1 3 "Choice [1-3]"
    _update_target="$_pm_latest"
}

prompt_source() {
    clear_step
    if [ "${_install_mode:-0}" -eq 0 ]; then
        say_header "Welcome to MailiaM."
        say_hint "Fresh install. No existing binary found at ${_bin_file}."
        say ""
    fi
    say_header "Select download source:"
    say_opt 1 "GitHub repository" "Default: ${_repo:-Rezishon/stalwart}"
    say_opt 2 "Custom HTTPS URL"
    say_opt 3 "Local archive file"
    if [ -n "$_file" ]; then
        _src_def=3
    else
        _src_def=1
    fi
    prompt_choice _src_choice "$_src_def" 3 "Choice [1-3]"
    case "$_src_choice" in
        1)
            clear_step
            prompt_value _repo "${_repo:-Rezishon/stalwart}" validate_source \
                "Invalid download source." "GitHub repository [owner/repo]"
            _file=
            ;;
        2)
            clear_step
            prompt_value _repo "https://example.com/releases" validate_source \
                "Invalid download source." "HTTPS URL (e.g. https://example.com/releases)"
            _file=
            ;;
        3)
            clear_step
            prompt_value _file "${_file:-/path/to/mailiam.tar.gz}" validate_source \
                "Invalid download source." "Local archive path (e.g. /path/to/mailiam.tar.gz)"
            ;;
    esac
}

prompt_paths() {
    clear_step
    say_header "Installation paths:"
    printf '  - Binary:  %s\n' "$_bin_file"
    printf '  - Config:  %s\n' "$_conf_dir"
    printf '  - Data:    %s\n' "$_data_dir"
    printf '  - Logs:    %s\n' "$_log_dir"
    say ""
    say_header "Select installation path:"
    say_opt 1 "Standard system paths" "Default"
    say_opt 2 "Single base path" "e.g. /opt/mailiam"
    say_opt 3 "Advanced: customize each path"
    prompt_choice _path_choice 1 3 "Choice [1-3]"
    case "$_path_choice" in
        2)
            clear_step
            prompt_value _prefix /opt/mailiam validate_prefix "Invalid prefix." \
                "Base directory path"
            apply_paths
            ;;
        3)
            clear_step
            prompt_value _bin_dir "$_bin_dir" validate_prefix "Invalid path." "Binary directory"
            clear_step
            prompt_value _conf_dir "$_conf_dir" validate_prefix "Invalid path." "Config directory"
            clear_step
            prompt_value _data_dir "$_data_dir" validate_prefix "Invalid path." "Data directory"
            clear_step
            prompt_value _log_dir "$_log_dir" validate_prefix "Invalid path." "Log directory"
            _bin_file="${_bin_dir}/mailiam"
            _bin_legacy="${_bin_dir}/stalwart"
            _config_file="${_conf_dir}/config.json"
            set_env_file
            ;;
    esac
}

prompt_hostname_step() {
    _hn_def="$(hostname_default "$_hostname")"
    clear_step
    prompt_value _hostname "$_hn_def" validate_hostname "Invalid hostname." \
        "Server hostname (FQDN)"
}

prompt_ports() {
    clear_step
    say_header "Network listener ports:"
    printf '  - SMTP:         %-6s %s(Mail delivery)%s\n' "$_listen_smtp" "$CLR_HINT" "$CLR_RESET"
    printf '  - SMTPS:        %-6s %s(Client send, TLS)%s\n' "$_listen_submissions" "$CLR_HINT" "$CLR_RESET"
    printf '  - Submission:   %-6s %s(Client send, STARTTLS)%s\n' "$_listen_submission" "$CLR_HINT" "$CLR_RESET"
    printf '  - IMAP:         %-6s %s(Mail access)%s\n' "$_listen_imap" "$CLR_HINT" "$CLR_RESET"
    printf '  - POP3:         %-6s %s(Legacy access)%s\n' "$_listen_pop3" "$CLR_HINT" "$CLR_RESET"
    printf '  - ManageSieve:  %-6s %s(Mail filtering)%s\n' "$_listen_sieve" "$CLR_HINT" "$CLR_RESET"
    printf '  - HTTP:         %-6s %s(Web / ACME challenges)%s\n' "$_listen_http" "$CLR_HINT" "$CLR_RESET"
    printf '  - HTTPS:        %-6s %s(Relay SPA / WebUI / JMAP)%s\n' "$_listen_https" "$CLR_HINT" "$CLR_RESET"
    say ""
    say_header "Select port configuration:"
    say_opt 1 "Use standard ports" "Default"
    say_opt 2 "Advanced: customize individual ports"
    prompt_choice _port_choice 1 2 "Choice [1-2]"
    if [ "$_port_choice" = 2 ]; then
        _used_ports=
        clear_step
        prompt_port _listen_smtp "$_listen_smtp" "SMTP port"
        clear_step
        prompt_port _listen_submissions "$_listen_submissions" "SMTPS port"
        clear_step
        prompt_port _listen_submission "$_listen_submission" "Submission port"
        clear_step
        prompt_port _listen_imap "$_listen_imap" "IMAP port"
        clear_step
        prompt_port _listen_pop3 "$_listen_pop3" "POP3 port"
        clear_step
        prompt_port _listen_sieve "$_listen_sieve" "ManageSieve port"
        clear_step
        prompt_port _listen_http "$_listen_http" "HTTP port"
        clear_step
        prompt_port _listen_https "$_listen_https" "HTTPS port"
    fi
}

prompt_tls() {
    clear_step
    say_header "TLS / SSL encryption:"
    say_opt 1 "Automatic Let's Encrypt (ACME)" "Default"
    say_opt 2 "Custom certificate files" "Path to .crt and .key"
    say_opt 3 "Disabled / Plaintext" "Only if behind reverse proxy"
    prompt_choice _tls_choice 1 3 "Choice [1-3]"
    case "$_tls_choice" in
        1)
            _tls=true
            _tls_mode="Automatic Let's Encrypt (ACME)"
            clear_step
            prompt_value _acme_email "admin@${_hostname}" validate_email \
                "Invalid email." "ACME contact email"
            ;;
        2)
            _tls=true
            _tls_mode="Custom certificate files"
            clear_step
            prompt_value _tls_cert /etc/ssl/certs/fullchain.pem validate_prefix \
                "Invalid path." "TLS certificate path"
            clear_step
            prompt_value _tls_key /etc/ssl/private/privkey.pem validate_prefix \
                "Invalid path." "TLS private key path"
            ;;
        3)
            _tls=false
            _tls_mode="Disabled / Plaintext"
            ;;
    esac
}

dc_ic_label() {
    case "$1" in
        3) printf '%s\n' "Strict" ;;
        1) printf '%s\n' "Accept invalid" ;;
        *) printf '%s\n' "Disabled" ;;
    esac
}

dc_sec_label() {
    case "$1" in
        ssl) printf '%s\n' "SSL/TLS" ;;
        starttls) printf '%s\n' "STARTTLS" ;;
        *) printf '%s\n' "Plain" ;;
    esac
}

prompt_dc() {
    set_dc_defaults
    clear_step
    say_header "DeltaChat autoconfig endpoints:"
    printf '  - IMAP:        %s:%s %s(%s)%s\n' \
        "$_dc_imap_host" "$_dc_imap_port" "$CLR_HINT" "$(dc_sec_label "$_dc_imap_security")" "$CLR_RESET"
    printf '  - SMTP:        %s:%s %s(%s)%s\n' \
        "$_dc_smtp_host" "$_dc_smtp_port" "$CLR_HINT" "$(dc_sec_label "$_dc_smtp_security")" "$CLR_RESET"
    printf '  - Cert checks: %s %s(Automatic)%s\n' \
        "$(dc_ic_label "$_dc_ic")" "$CLR_HINT" "$CLR_RESET"
    say ""
    say_header "Configure DeltaChat endpoints:"
    say_opt 1 "Use server defaults" "Default"
    say_opt 2 "Advanced: customize DeltaChat endpoints"
    prompt_choice _dc_choice 1 2 "Choice [1-2]"
    if [ "$_dc_choice" = 2 ]; then
        clear_step
        prompt_value _dc_imap_host "$_dc_imap_host" validate_hostname "Invalid hostname." \
            "DeltaChat IMAP host"
        clear_step
        prompt_port _dc_imap_port "$_dc_imap_port" "DeltaChat IMAP port" nodup
        clear_step
        prompt_value _dc_imap_security "$_dc_imap_security" validate_dc_security \
            "Invalid DeltaChat security." "DeltaChat IMAP security [ssl/starttls/default/plain]"
        clear_step
        prompt_value _dc_smtp_host "$_dc_smtp_host" validate_hostname "Invalid hostname." \
            "DeltaChat SMTP host"
        clear_step
        prompt_port _dc_smtp_port "$_dc_smtp_port" "DeltaChat SMTP port" nodup
        clear_step
        prompt_value _dc_smtp_security "$_dc_smtp_security" validate_dc_security \
            "Invalid DeltaChat security." "DeltaChat SMTP security [ssl/starttls/default/plain]"
        clear_step
        prompt_value _dc_ic "$_dc_ic" validate_dc_ic "Invalid DeltaChat ic." \
            "DeltaChat certificate checks [0/1/3]"
    fi
}

prompt_public_url_step() {
    set_public_url_default
    clear_step
    prompt_value _public_url "$_public_url" validate_public_url "Invalid public URL." \
        "Public web URL (/admin, /account, DeltaChat)"
}

print_box_title() {
    print_hr
    printf '%s%s%s\n' "$CLR_BOLD" "$1" "$CLR_RESET"
    print_hr
}

src_display() {
    if [ -n "$_file" ]; then
        printf '%s\n' "$_file"
    else
        printf '%s (%s)\n' "$_repo" "$_version"
    fi
}

print_install_summary() {
    clear_step
    print_box_title "                    MailiaM Installation Summary"
    printf '  Download Source:   %s\n' "$(src_display)"
    printf '  Install Base:      %s (Binary: %s)\n' "$_prefix" "$_bin_file"
    printf '  Service User:      %s (unprivileged)\n' "$_account"
    printf '  Server Hostname:   %s\n' "$_hostname"
    printf '  Web URL:           %s%s%s\n' "$CLR_URL" "$_public_url" "$CLR_RESET"
    say ""
    say_header "  Active Listeners:"
    printf '    - SMTP (MTA):    Port %s\n' "$_listen_smtp"
    printf '    - SMTPS:         Port %s (Implicit TLS)\n' "$_listen_submissions"
    printf '    - Submission:    Port %s (STARTTLS)\n' "$_listen_submission"
    printf '    - IMAP:          Port %s\n' "$_listen_imap"
    printf '    - ManageSieve:   Port %s\n' "$_listen_sieve"
    printf '    - Web (HTTP):    Port %s\n' "$_listen_http"
    printf '    - Web (HTTPS):   Port %s\n' "$_listen_https"
    say ""
    printf '  %sTLS / SSL:%s         %s\n' "$CLR_BOLD" "$CLR_RESET" "${_tls_mode:-$_tls}"
    say ""
    say_header "  DeltaChat Config:"
    printf '    - Web & Relay:   %s/\n' "$_public_url"
    printf '    - IMAP Server:   %s:%s (%s)\n' "$_dc_imap_host" "$_dc_imap_port" "$(dc_sec_label "$_dc_imap_security")"
    printf '    - SMTP Server:   %s:%s (%s)\n' "$_dc_smtp_host" "$_dc_smtp_port" "$(dc_sec_label "$_dc_smtp_security")"
    printf '    - Cert Checks:   %s (ic=%s)\n' "$(dc_ic_label "$_dc_ic")" "$_dc_ic"
    say ""
    if [ "$_admin" = random ] || [ -z "${_admin:-}" ]; then
        printf '  %sAdmin Account:%s     admin (password generated next)\n' \
            "$CLR_BOLD" "$CLR_RESET"
    else
        printf '  %sAdmin Account:%s     %s\n' \
            "$CLR_BOLD" "$CLR_RESET" "${_admin%%:*}"
    fi
    if [ "${_SKIP_START:-0}" -eq 0 ]; then
        printf '  %sService Start:%s     Yes (%s)\n' "$CLR_BOLD" "$CLR_RESET" "${_init:-none}"
    else
        printf '  %sService Start:%s     No\n' "$CLR_BOLD" "$CLR_RESET"
    fi
    print_hr
}

print_update_summary() {
    clear_step
    print_box_title "                    MailiaM Binary Update Summary"
    printf '  Current Binary:    %s' "${_existing_bin:-$_bin_file}"
    _uv="$(installed_version "${_existing_bin:-$_bin_file}")"
    if [ -n "$_uv" ]; then
        printf ' %s(version %s)%s' "$CLR_HINT" "$_uv" "$CLR_RESET"
    fi
    printf '\n'
    printf '  Target Version:    %s %s(from %s)%s\n' \
        "$_version" "$CLR_HINT" "${_file:-$_repo}" "$CLR_RESET"
    printf '  Config & Env:      %sPreserved%s %s(%s)%s\n' \
        "$CLR_GREEN" "$CLR_RESET" "$CLR_HINT" "$_conf_dir" "$CLR_RESET"
    printf '  Mail Database:     %sPreserved%s %s(%s)%s\n' \
        "$CLR_GREEN" "$CLR_RESET" "$CLR_HINT" "$_data_dir" "$CLR_RESET"
    if [ "${_SKIP_START:-0}" -eq 0 ]; then
        printf '  Service Action:    Restart mailiam service\n'
    else
        printf '  Service Action:    Leave service stopped\n'
    fi
    print_hr
}

print_install_success() {
    if [ -n "${_admin:-}" ] && [ "$_admin" != random ]; then
        _pw_user="${_admin%%:*}"
        _pw="${_admin#*:}"
    else
        _pw_user=admin
        _pw="(see MAILIAM_RECOVERY_ADMIN in ${_env_file})"
    fi
    say ""
    print_box_title "                  MailiaM Installed Successfully"
    say ""
    say_header "  Admin Web Console:"
    printf '    URL:             %s%s/admin%s\n' "$CLR_URL" "$_public_url" "$CLR_RESET"
    printf '    Username:        %s\n' "$_pw_user"
    printf '    Password:        %s%s%s\n' "$CLR_GREEN" "$_pw" "$CLR_RESET"
    say ""
    say_header "  User Portal & Web Apps:"
    printf '    DeltaChat Relay: %s%s/%s\n' "$CLR_URL" "$_public_url" "$CLR_RESET"
    printf '    User Account:    %s%s/account%s\n' "$CLR_URL" "$_public_url" "$CLR_RESET"
    say ""
    say_header "  Useful Commands:"
    print_service_hints
    printf '    Config file:     %s\n' "$_env_file"
    say ""
    print_hr
}

print_update_success() {
    _from="${_from_ver:-unknown}"
    _to="${_to_ver:-$_version}"
    [ -n "$_to" ] || _to=unknown
    say ""
    print_box_title "                    MailiaM Updated Successfully"
    say ""
    printf '  %sInstalled Version:%s  %s%s => %s%s\n' \
        "$CLR_BOLD" "$CLR_RESET" "$CLR_URL" "$_from" "$_to" "$CLR_RESET"
    printf '  %sBinary Path:%s        %s\n' "$CLR_BOLD" "$CLR_RESET" "$_bin_file"
    printf '  %sService Status:%s     updated\n' "$CLR_BOLD" "$CLR_RESET"
    say ""
    say_header "  Useful Commands:"
    print_service_hints
    say ""
    print_hr
}

confirm_or_abort() {
    say ""
    prompt_yes_no _go Y "$1"
    if ! is_yes "$_go"; then
        say "Aborted. No changes were made."
        exit 0
    fi
}

ensure_bin_symlink() {
    if [ -n "${_bin_legacy:-}" ] && [ "$_bin_legacy" != "$_bin_file" ]; then
        if [ -e "$_bin_legacy" ] && [ ! -L "$_bin_legacy" ]; then
            if [ ! -e "$_bin_file" ]; then
                mv "$_bin_legacy" "$_bin_file"
            else
                rm -f "$_bin_legacy"
            fi
        fi
        ln -sfn mailiam "$_bin_legacy"
    fi
}

ensure_conf_symlink() {
    [ "$_prefix" = /usr/local ] || return 0
    if [ "$_os" = freebsd ]; then
        _legacy_conf=/usr/local/etc/stalwart
    else
        _legacy_conf=/etc/stalwart
    fi
    if [ ! -e "$_legacy_conf" ]; then
        ln -sfn mailiam "$_legacy_conf"
    fi
}

adopt_existing_layout() {
    [ "$_prefix" = /usr/local ] || return 0
    [ -d "$_conf_dir" ] && return 0
    if [ "$_os" = freebsd ]; then
        _old_conf=/usr/local/etc/stalwart
        _old_data=/var/db/stalwart
    else
        _old_conf=/etc/stalwart
        _old_data=/var/lib/stalwart
    fi
    _old_log=/var/log/stalwart
    if [ -d "$_old_conf" ] && [ ! -L "$_old_conf" ]; then
        _conf_dir="$_old_conf"
        [ -d "$_old_data" ] && _data_dir="$_old_data"
        [ -d "$_old_log" ] && _log_dir="$_old_log"
        _config_file="${_conf_dir}/config.json"
        set_env_file
    fi
}

set_env_file() {
    _env_file="${_conf_dir}/mailiam.env"
    if [ ! -e "$_env_file" ] && [ -e "${_conf_dir}/stalwart.env" ]; then
        _env_file="${_conf_dir}/stalwart.env"
    fi
}

apply_paths() {
    eval "$(resolve_paths "$_prefix" "$_os")" || err "Invalid prefix: $_prefix"
    _bin_file="${_bin_dir}/mailiam"
    _bin_legacy="${_bin_dir}/stalwart"
    _config_file="${_conf_dir}/config.json"
    set_env_file
}

apply_source() {
    case "$1" in
        https://*)
            _file=
            _repo="$1"
            ;;
        *.tar.gz)
            _file="$1"
            ;;
        *)
            _file=
            _repo="$1"
            ;;
    esac
}

comment_env_key() {
    _cek_file="$1"
    _cek_key="$2"
    [ -f "$_cek_file" ] || return 0
    _out=$(mktemp)
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            "${_cek_key}="*)
                printf '#%s\n' "$_line"
                ;;
            *)
                printf '%s\n' "$_line"
                ;;
        esac
    done < "$_cek_file" > "$_out"
    cat "$_out" > "$_cek_file"
    rm -f "$_out"
}

apply_mode2_admin() {
    if [ -n "$_admin" ] && [ "$_admin" != random ]; then
        upsert_env "$1" MAILIAM_RECOVERY_ADMIN "$_admin"
    elif [ "$_admin" = random ]; then
        comment_env_key "$1" MAILIAM_RECOVERY_ADMIN
        comment_env_key "$1" STALWART_RECOVERY_ADMIN
    fi
}

read_env_key() {
    _rek_file="$1"
    _rek_key="$2"
    _rek_val=
    [ -r "$_rek_file" ] || return 1
    while IFS= read -r _rek_line || [ -n "$_rek_line" ]; do
        case "$_rek_line" in
            "${_rek_key}="*)
                _rek_val="${_rek_line#*=}"
                case "$_rek_val" in
                    \'*\'|\"*\")
                        _rek_val="${_rek_val#?}"
                        _rek_val="${_rek_val%?}"
                        ;;
                esac
                ;;
        esac
    done < "$_rek_file"
    [ -n "$_rek_val" ] || return 1
    printf '%s\n' "$_rek_val"
}

read_env_key_mail() { # file new old
    read_env_key "$1" "$2" || read_env_key "$1" "$3"
}

set_public_url_default() {
    if [ -n "$_public_url" ]; then
        return 0
    fi
    if [ "$_tls" = false ] || [ "$_tls" = 0 ]; then
        if [ -n "$_listen_http" ] && [ "$_listen_http" != 80 ]; then
            _public_url="http://${_hostname}:${_listen_http}"
        else
            _public_url="http://${_hostname}"
        fi
    else
        if [ -n "$_listen_https" ] && [ "$_listen_https" != 443 ]; then
            _public_url="https://${_hostname}:${_listen_https}"
        else
            _public_url="https://${_hostname}"
        fi
    fi
}

seed_mode2_from_env() {
    _v=
    if [ -z "${_hostname_arg:-}" ]; then
        _v="$(read_env_key_mail "$_env_file" MAILIAM_HOSTNAME STALWART_HOSTNAME)" || _v=
        if [ -n "$_v" ] && validate_hostname "$_v"; then
            _hostname="$_v"
        fi
    fi
    if [ -z "${_public_url_arg:-}" ]; then
        _v="$(read_env_key_mail "$_env_file" MAILIAM_PUBLIC_URL STALWART_PUBLIC_URL)" || _v=
        if [ -n "$_v" ] && validate_public_url "$_v"; then
            _public_url="$_v"
        else
            _public_url=
            _v="$(read_env_key_mail "$_env_file" MAILIAM_LISTEN_HTTPS STALWART_LISTEN_HTTPS)" || _v=
            if validate_port "$_v"; then
                _listen_https="$_v"
            fi
        fi
    fi
}

set_dc_defaults() {
    [ -n "$_dc_imap_host" ] || _dc_imap_host="$_hostname"
    [ -n "$_dc_smtp_host" ] || _dc_smtp_host="$_hostname"
    if [ "$_tls" = false ] || [ "$_tls" = 0 ]; then
        [ -n "$_dc_imap_port" ] || _dc_imap_port=143
        [ -n "$_dc_smtp_port" ] || _dc_smtp_port=587
        [ -n "$_dc_imap_security" ] || _dc_imap_security=plain
        [ -n "$_dc_smtp_security" ] || _dc_smtp_security=plain
        [ -n "$_dc_ic" ] || _dc_ic=0
    else
        [ -n "$_dc_imap_port" ] || _dc_imap_port=993
        [ -n "$_dc_smtp_port" ] || _dc_smtp_port=465
        [ -n "$_dc_imap_security" ] || _dc_imap_security=ssl
        [ -n "$_dc_smtp_security" ] || _dc_smtp_security=ssl
        [ -n "$_dc_ic" ] || _dc_ic=3
    fi
}

extract_mailiam() {
    _tar="$1"
    _outdir="$2"
    _member=
    _n_members=0
    while IFS= read -r _n; do
        [ -z "$_n" ] && continue
        case "$_n" in
            *..*|/*)
                err "Archive contains an unsafe path."
                ;;
            mailiam|./mailiam|stalwart|./stalwart)
                _member="$_n"
                _n_members=$((_n_members + 1))
                ;;
            *)
                err "Archive must contain only mailiam."
                ;;
        esac
    done <<EOF
$(tar -t -f "$_tar")
EOF
    [ "$_n_members" -eq 1 ] && [ -n "$_member" ] || err "Archive must contain only mailiam."
    ensure tar --no-same-owner -xf "$_tar" -C "$_outdir" "$_member"
    _extracted="${_outdir}/${_member#./}"
    [ -f "$_extracted" ] && [ ! -L "$_extracted" ] || err "Archive member must be a regular file named mailiam."
}

# Same-dir rename unlinks a running dest (ETXTBSY). Cross-device cp onto an
# executing inode fails; this never opens the dest for write.
replace_binary() {
    _rb_dest="$1"
    _rb_src="$2"
    _rb_new="${_rb_dest}.new.$$"
    if ! cp "$_rb_src" "$_rb_new"; then
        rm -f "$_rb_new"
        return 1
    fi
    if ! chmod 0755 "$_rb_new"; then
        rm -f "$_rb_new"
        return 1
    fi
    if ! mv "$_rb_new" "$_rb_dest"; then
        rm -f "$_rb_new"
        return 1
    fi
    return 0
}

# systemd: /run/systemd/system (not merely systemctl in PATH — containers lie).
# openrc before sysv: Alpine has /etc/init.d too.
init_from_hints() {
    case "$1" in
        freebsd) printf '%s\n' freebsd ;;
        linux)
            if [ "$2" = y ]; then
                printf '%s\n' systemd
            elif [ "$3" = y ]; then
                printf '%s\n' openrc
            elif [ "$4" = y ]; then
                printf '%s\n' sysv
            else
                printf '%s\n' none
            fi
            ;;
        *) printf '%s\n' none ;;
    esac
}

detect_init() {
    _di_systemd=n
    _di_openrc=n
    _di_initd=n
    [ -d /run/systemd/system ] && _di_systemd=y
    if [ -x /sbin/openrc-run ] && check_cmd rc-service; then
        _di_openrc=y
    fi
    [ -d /etc/init.d ] && _di_initd=y
    _init="$(init_from_hints "${_os:-}" "$_di_systemd" "$_di_openrc" "$_di_initd")"
}

stop_service() {
    case "${_init:-}" in
        systemd) systemctl stop mailiam 2>/dev/null || true ;;
        sysv)
            service mailiam stop 2>/dev/null ||
                /etc/init.d/mailiam stop 2>/dev/null || true
            ;;
        openrc) rc-service mailiam stop 2>/dev/null || true ;;
        freebsd) service mailiam stop 2>/dev/null || true ;;
    esac
}

print_service_hints() {
    case "${_init:-}" in
        systemd)
            printf '    Check status:    %ssystemctl status mailiam%s\n' "$CLR_HINT" "$CLR_RESET"
            printf '    View live logs:  %sjournalctl -u mailiam -f%s\n' "$CLR_HINT" "$CLR_RESET"
            ;;
        openrc)
            printf '    Check status:    %src-service mailiam status%s\n' "$CLR_HINT" "$CLR_RESET"
            printf '    View live logs:  %stail -f %s/mailiam.log%s\n' "$CLR_HINT" "$_log_dir" "$CLR_RESET"
            ;;
        sysv)
            printf '    Check status:    %sservice mailiam status%s\n' "$CLR_HINT" "$CLR_RESET"
            printf '    View live logs:  %stail -f %s/mailiam.log%s\n' "$CLR_HINT" "$_log_dir" "$CLR_RESET"
            ;;
        freebsd)
            printf '    Check status:    %sservice mailiam status%s\n' "$CLR_HINT" "$CLR_RESET"
            printf '    View live logs:  %stail -f %s/mailiam.log%s\n' "$CLR_HINT" "$_log_dir" "$CLR_RESET"
            ;;
        *)
            printf '    Start:            %sset -a; . %s; set +a; %s --config=%s%s\n' \
                "$CLR_HINT" "${_env_file:-/etc/mailiam/mailiam.env}" \
                "${_bin_file:-/usr/local/bin/mailiam}" \
                "${_config_file:-/etc/mailiam/config.json}" "$CLR_RESET"
            printf '    View live logs:  %stail -f %s/mailiam.log%s\n' "$CLR_HINT" "$_log_dir" "$CLR_RESET"
            ;;
    esac
}

install_binary() {
    _target="$1"
    _tmp="$(mktemp -d)"
    if [ -n "$_file" ]; then
        _tar="$_file"
        say "Using local archive ${_tar}..."
    else
        _tar="${_tmp}/mailiam.tar.gz"
        _url="$(download_url "$_repo" "$_version" "$_target")" || err "Invalid download source."
        say "Downloading MailiaM for ${_target}..."
        if ! downloader "$_url" "$_tar" "$_target"; then
            rm -rf "$_tmp"
            err "Download failed."
        fi
        say "Download complete."
    fi
    say "Extracting archive..."
    extract_mailiam "$_tar" "$_tmp"
    if [ -e "$_bin_file" ]; then
        say "Backing up ${_bin_file}..."
        ensure cp "$_bin_file" "${_bin_file}.bak"
        say "Stopping mailiam..."
        stop_service
    fi
    say "Installing binary to ${_bin_file}..."
    if ! replace_binary "$_bin_file" "$_extracted"; then
        if [ -f "${_bin_file}.bak" ]; then
            mv "${_bin_file}.bak" "$_bin_file"
        fi
        rm -rf "$_tmp"
        err "Failed to install binary."
    fi
    ensure chmod 0755 "$_bin_file"
    ensure chown root:root "$_bin_file"
    ensure_bin_symlink
    rm -rf "$_tmp"
    say "Binary installed."
}

recovery_port() {
    _rp_file="${1:-}"
    _rp=
    if [ -n "$_rp_file" ]; then
        _rp="$(read_env_key_mail "$_rp_file" MAILIAM_RECOVERY_MODE_PORT STALWART_RECOVERY_MODE_PORT)" || _rp=
        if validate_port "$_rp" && [ "$_rp" != 0 ]; then
            printf '%s\n' "$_rp"
            return 0
        fi
        _rp="$(read_env_key_mail "$_rp_file" MAILIAM_LISTEN_HTTP STALWART_LISTEN_HTTP)" || _rp=
        if validate_port "$_rp" && [ "$_rp" != 0 ]; then
            printf '%s\n' "$_rp"
            return 0
        fi
        printf '%s\n' 80
        return 0
    fi
    printf '%s\n' 80
}

main() {
    local _os _uname _account=""
    local _prefix=""
    local _yes=0 _update=0 _no_start=0
    local _repo="Rezishon/stalwart" _version="latest" _file=""
    _hostname=""
    _public_url=""
    _hostname_arg=""
    _public_url_arg=""
    _listen_smtp=25
    _listen_submission=587
    _listen_submissions=465
    _listen_imap=143
    _listen_pop3=110
    _listen_sieve=4190
    _listen_https=443
    _listen_http=80
    _tls=true
    _tls_mode="Automatic Let's Encrypt (ACME)"
    _acme_email=
    _tls_cert=
    _tls_key=
    _dc_imap_host=""
    _dc_imap_port=""
    _dc_imap_security=""
    _dc_smtp_host=""
    _dc_smtp_port=""
    _dc_smtp_security=""
    _dc_ic=""
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

    _hostname_arg="$_hostname"
    _public_url_arg="$_public_url"

    if [ ! -t 0 ] && [ "$_yes" -eq 0 ] && [ "$_update" -eq 0 ]; then
        err "Non-interactive stdin requires -y or --update."
    fi
    _interactive=0
    if [ -t 0 ] && [ "$_yes" -eq 0 ] && [ "$_update" -eq 0 ]; then
        _interactive=1
    fi
    init_colors

    need_cmd uname
    need_cmd hostname
    _uname="$(uname)"
    case "$_uname" in
        Linux)   _os="linux"; [ -n "$_account" ] || _account="mailiam" ;;
        FreeBSD) _os="freebsd"; [ -n "$_account" ] || _account="mailiam" ;;
        *)       err "❌ Install failed: Unsupported OS: $_uname" ;;
    esac
    detect_init

    downloader --check
    need_cmd mktemp
    need_cmd chmod
    need_cmd chown
    need_cmd mkdir
    need_cmd rm
    need_cmd tar
    need_cmd cp
    need_cmd mv

    if [ "$(id -u)" -ne 0 ]; then
        err "❌ Install failed: This program needs to run as root."
    fi

    [ -n "$_prefix" ] || _prefix=/usr/local
    if [ -z "$_hostname" ]; then
        _hostname="$(hostname -f 2>/dev/null || hostname || printf '%s\n' mail.localhost)"
        _hostname="$(hostname_default "$_hostname")"
    fi
    apply_paths
    adopt_existing_layout

    _target="$(artifact_target "$_uname" "$(uname -m)")" || err "❌ Install failed: Unsupported OS or architecture."

    _install_mode=0
    _existing_bin=$(detect_installed_bin) || _existing_bin=
    if [ "$_update" -eq 1 ]; then
        _install_mode=1
    elif [ -n "$_existing_bin" ]; then
        if [ "$_yes" -eq 1 ]; then
            _install_mode=1
        else
            prompt_mode "$_existing_bin"
        fi
    fi

    if [ "$_interactive" -eq 1 ]; then
        if [ "$_install_mode" -ne 2 ]; then
            prompt_source
            if [ -z "$_file" ]; then
                if [ "$_install_mode" -eq 1 ]; then
                    _ver_label="Release version to install"
                else
                    _ver_label="Release version"
                fi
                clear_step
                prompt_value _version "$_version" validate_version "Invalid version." \
                    "$_ver_label"
            fi
        fi

        if [ "$_install_mode" -eq 1 ]; then
            if [ "$_no_start" -eq 0 ]; then
                clear_step
                prompt_yes_no _start_ans Y "Restart MailiaM service after update? [Y/n]"
                if is_yes "$_start_ans"; then
                    _SKIP_START=0
                else
                    _SKIP_START=1
                fi
            else
                _SKIP_START=1
            fi
            print_update_summary
            confirm_or_abort "Proceed with update? [Y/n]"
        elif [ "$_install_mode" -eq 2 ]; then
            seed_mode2_from_env
            prompt_hostname_step
            prompt_public_url_step
            prompt_admin keep
            if [ "$_no_start" -eq 0 ]; then
                clear_step
                prompt_yes_no _start_ans Y "Enable and start MailiaM service now? [Y/n]"
                if is_yes "$_start_ans"; then
                    _SKIP_START=0
                else
                    _SKIP_START=1
                fi
            else
                _SKIP_START=1
            fi
            confirm_or_abort "Proceed with reconfigure? [Y/n]"
        else
            prompt_paths
            clear_step
            prompt_value _account "$_account" validate_user "Invalid user." \
                "MailiaM user account"
            prompt_hostname_step
            prompt_ports
            prompt_tls
            prompt_dc
            prompt_public_url_step
            prompt_admin
            if [ "$_no_start" -eq 0 ]; then
                clear_step
                prompt_yes_no _start_ans Y "Enable and start MailiaM service now? [Y/n]"
                if is_yes "$_start_ans"; then
                    _SKIP_START=0
                else
                    _SKIP_START=1
                fi
            else
                _SKIP_START=1
            fi
            print_install_summary
            confirm_or_abort "Proceed with installation? [Y/n]"
        fi
    else
        set_public_url_default
        set_dc_defaults
        if [ "$_no_start" -eq 1 ]; then
            _SKIP_START=1
        else
            _SKIP_START=0
        fi
    fi

    create_account "$_os" "$_account"
    say "Creating directories..."
    ensure mkdir -p "$_bin_dir" "$_conf_dir" "$_log_dir" "$_data_dir"
    ensure_conf_symlink

    if [ "$_install_mode" -ne 2 ]; then
        _from_ver="$(installed_version "${_existing_bin:-$_bin_file}")" || _from_ver=
        install_binary "$_target"
        _to_ver="$(installed_version "$_bin_file")" || _to_ver=
        [ -n "$_to_ver" ] || _to_ver="$_version"
    fi

    case "$_install_mode" in
        1)
            ;;
        2)
            if [ ! -e "$_env_file" ]; then
                : > "$_env_file"
                chmod 0640 "$_env_file"
            fi
            upsert_env "$_env_file" MAILIAM_HOSTNAME "$_hostname"
            upsert_env "$_env_file" MAILIAM_PUBLIC_URL "$_public_url"
            apply_mode2_admin "$_env_file"
            ;;
        *)
            ensure_generated_admin
            say "Writing env file at ${_env_file}..."
            write_env_file "$_env_file"
            ;;
    esac

    say "Setting permissions..."
    ensure chown "${_account}:${_account}" "$_conf_dir" "$_log_dir" "$_data_dir"
    ensure chmod 0750 "$_conf_dir" "$_log_dir" "$_data_dir"
    if [ -e "$_env_file" ]; then
        ensure chown "root:${_account}" "$_env_file"
        ensure chmod 0640 "$_env_file"
    fi

    case "${_init}" in
        systemd)
            say "Installing systemd unit..."
            create_service_linux_systemd "$_bin_file" "$_config_file" "$_env_file" "$_account"
            ;;
        sysv)
            say "Installing SysV init script..."
            create_service_linux_initd "$_bin_file" "$_config_file" "$_env_file" "$_account" "$_log_dir"
            ;;
        openrc)
            say "Installing OpenRC service..."
            create_service_linux_openrc "$_bin_file" "$_config_file" "$_env_file" "$_account"
            ;;
        freebsd)
            say "Installing FreeBSD rc.d script..."
            create_service_freebsd "$_bin_file" "$_config_file" "$_env_file" "$_account" "$_log_dir"
            ;;
        *)
            say "No init system detected; start ${_bin_file} --config=${_config_file} yourself."
            ;;
    esac
    if [ "${_init}" != none ] && [ "${_SKIP_START:-0}" -eq 0 ]; then
        say "Service started."
    elif [ "${_init}" != none ]; then
        say "Service left stopped."
    fi

    case "$_install_mode" in
        1) print_update_success ;;
        2)
            say ""
            say "Environment updated at ${_env_file}."
            say ""
            ;;
        *) print_install_success ;;
    esac

    return 0
}

print_usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS] [PREFIX]

Install MailiaM into standard FHS paths or under a custom prefix.

Options:
  -y, --yes, --non-interactive  Non-interactive install using defaults
  -u, --update                  Update binary only
  --repo <repo|url>             GitHub owner/repo or https base URL
  --version <tag>               Release tag (default: latest)
  --file <path>                 Local .tar.gz archive
  --prefix <path>               Installation prefix
  --user <name>                 Service account (default: mailiam)
  --hostname <host>             MAILIAM_HOSTNAME
  --public-url <url>            MAILIAM_PUBLIC_URL
  --admin <user:pass>           Custom admin; omit for random
  --smtp-port <n>               MAILIAM_LISTEN_SMTP (default: 25)
  --submission-port <n>         MAILIAM_LISTEN_SUBMISSION (default: 587)
  --submissions-port <n>        MAILIAM_LISTEN_SUBMISSIONS (default: 465)
  --imap-port <n>               MAILIAM_LISTEN_IMAP (default: 143)
  --pop3-port <n>               MAILIAM_LISTEN_POP3 (default: 110)
  --sieve-port <n>              MAILIAM_LISTEN_SIEVE (default: 4190)
  --https-port <n>              MAILIAM_LISTEN_HTTPS (default: 443)
  --http-port <n>               MAILIAM_LISTEN_HTTP (default: 80)
  --tls / --no-tls              MAILIAM_TLS=true / false (default: --tls)
  --dc-imap-host <host>         MAILIAM_DC_IMAP_HOST
  --dc-imap-port <n>            MAILIAM_DC_IMAP_PORT
  --dc-imap-security <s>        MAILIAM_DC_IMAP_SECURITY (default: ssl)
  --dc-smtp-host <host>         MAILIAM_DC_SMTP_HOST
  --dc-smtp-port <n>            MAILIAM_DC_SMTP_PORT
  --dc-smtp-security <s>        MAILIAM_DC_SMTP_SECURITY (default: ssl)
  --dc-ic <0|1|3>               MAILIAM_DC_IC (default: 3)
  --no-start                    Do not start or restart the service
  -h, --help                    Show this help

PREFIX may also be given as a single positional argument. If both are
given, the last --prefix wins. Extra positionals are an error.

With no PREFIX, MailiaM is installed under standard FHS paths:
  binary   /usr/local/bin/mailiam          (stalwart symlink for compatibility)
  config   /etc/mailiam/config.json        (/usr/local/etc/mailiam/config.json on FreeBSD)
  env      /etc/mailiam/mailiam.env        (/usr/local/etc/mailiam/mailiam.env on FreeBSD)
  logs     /var/log/mailiam/
  data     /var/lib/mailiam/               (/var/db/mailiam on FreeBSD)

When PREFIX is provided, a self-contained layout is used instead:
  binary   $PREFIX/bin/mailiam
  config   $PREFIX/etc/config.json
  env      $PREFIX/etc/mailiam.env
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
        printf '%s\n' '# Environment variables for the MailiaM service.'
        printf '%s\n' '# Uncomment and edit an entry to override its default.'
        printf '\n'
        printf '%s\n' '# Override the hostname used in HTTP responses'
        emit_env MAILIAM_HOSTNAME "$_hostname" || return 1
        printf '\n'
        printf '%s\n' '# Override the public base URL published in OAuth, OIDC, and JMAP discovery'
        printf '%s\n' '# documents. Accepts scheme, host, optional port, and optional path prefix.'
        emit_env MAILIAM_PUBLIC_URL "$_public_url" || return 1
        printf '\n'
        printf '%s\n' '# First-boot listeners. Port 0 skips that listener.'
        emit_env MAILIAM_LISTEN_SMTP "$_listen_smtp" || return 1
        emit_env MAILIAM_LISTEN_SUBMISSION "$_listen_submission" || return 1
        emit_env MAILIAM_LISTEN_SUBMISSIONS "$_listen_submissions" || return 1
        emit_env MAILIAM_LISTEN_IMAP "$_listen_imap" || return 1
        emit_env MAILIAM_LISTEN_POP3 "$_listen_pop3" || return 1
        emit_env MAILIAM_LISTEN_SIEVE "$_listen_sieve" || return 1
        emit_env MAILIAM_LISTEN_HTTPS "$_listen_https" || return 1
        emit_env MAILIAM_LISTEN_HTTP "$_listen_http" || return 1
        printf '\n'
        printf '%s\n' '# TLS on inserted listeners (1/true/0/false).'
        emit_env MAILIAM_TLS "$_tls" || return 1
        printf '\n'
        printf '%s\n' '# DeltaChat advertised endpoints (first insert only).'
        emit_env MAILIAM_DC_IMAP_HOST "$_dc_imap_host" || return 1
        emit_env MAILIAM_DC_IMAP_PORT "$_dc_imap_port" || return 1
        emit_env MAILIAM_DC_IMAP_SECURITY "$_dc_imap_security" || return 1
        emit_env MAILIAM_DC_SMTP_HOST "$_dc_smtp_host" || return 1
        emit_env MAILIAM_DC_SMTP_PORT "$_dc_smtp_port" || return 1
        emit_env MAILIAM_DC_SMTP_SECURITY "$_dc_smtp_security" || return 1
        emit_env MAILIAM_DC_IC "$_dc_ic" || return 1
        if [ -n "${_admin:-}" ] && [ "$_admin" != random ]; then
            printf '\n'
            printf '%s\n' '# Fixed administrator credentials — format: username:password'
            emit_env MAILIAM_RECOVERY_ADMIN "$_admin" || return 1
        fi
        printf '\n'
        printf '%s\n' '# Cluster role assigned to this node. Must match a role name defined in the'
        printf '%s\n' '# cluster registry. Leave unset for a standalone (non-clustered) deployment.'
        printf '%s\n' '#MAILIAM_ROLE=primary'
        printf '\n'
        printf '%s\n' '# Push-notification shard this node is responsible for, when running in a'
        printf '%s\n' '# cluster.'
        printf '%s\n' '#MAILIAM_PUSH_SHARD=1'
    } > "$1" || return 1
    chmod 0640 "$1"
}

create_account() {
    local _os="$1"
    local _account="$2"
    if id -u "$_account" > /dev/null 2>&1; then
        return 0
    fi
    say "Creating '${_account}' account..."
    if [ "$_os" = "freebsd" ]; then
        ensure pw useradd -n "$_account" -c "MailiaM service" -d /nonexistent -s /usr/sbin/nologin -w no
    else
        ensure useradd "$_account" -s /usr/sbin/nologin -M -r -U
    fi
}

create_service_linux_systemd() {
    local _bin="$1" _config="$2" _env="$3" _user="$4"
    cat > /etc/systemd/system/mailiam.service <<EOF
[Unit]
Description=MailiaM
Conflicts=postfix.service sendmail.service exim4.service stalwart.service
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
SyslogIdentifier=mailiam
User=${_user}
Group=${_user}
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable mailiam.service
    if [ "${_SKIP_START:-0}" -eq 0 ]; then
        systemctl restart mailiam.service
    fi
}

create_service_linux_initd() {
    local _bin="$1" _config="$2" _env="$3" _user="$4" _log_dir="${5:-/var/log/mailiam}"
    mkdir -p /etc/init.d
    cat > /etc/init.d/mailiam <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          mailiam
# Required-Start:    \$network
# Required-Stop:     \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: MailiaM Server
# Description:       Starts and stops the MailiaM Server
# Conflicts:         postfix sendmail stalwart
### END INIT INFO

PATH=/sbin:/usr/sbin:/bin:/usr/bin

. /lib/init/vars.sh
. /lib/lsb/init-functions

DAEMON=${_bin}
DAEMON_ARGS="--config=${_config}"
ENV_FILE=${_env}
LOG_FILE="${_log_dir}/mailiam.log"
PIDFILE=/var/run/mailiam.pid
ULIMIT_NOFILE=65536

[ -x "\$DAEMON" ] || exit 0

if [ -r "\$ENV_FILE" ]; then
    set -a
    . "\$ENV_FILE"
    set +a
fi

export RUN_AS_USER=${_user}
export RUN_AS_GROUP=${_user}

ulimit -n \$ULIMIT_NOFILE

do_start()
{
    start-stop-daemon --start --quiet --pidfile \$PIDFILE --exec \$DAEMON --test > /dev/null \\
        || return 1
    start-stop-daemon --start --quiet --pidfile \$PIDFILE --exec \$DAEMON \\
        --background --make-pidfile --output "\$LOG_FILE" \\
        -- \$DAEMON_ARGS \\
        || return 2
}

do_stop()
{
    start-stop-daemon --stop --quiet --retry=INT/30/KILL/5 --pidfile \$PIDFILE --name mailiam
    RETVAL="\$?"
    [ "\$RETVAL" = 2 ] && return 2
    start-stop-daemon --stop --quiet --oknodo --retry=0/30/KILL/5 --exec \$DAEMON
    [ "\$?" = 2 ] && return 2
    rm -f \$PIDFILE
    return "\$RETVAL"
}

case "\$1" in
  start)
    [ "\$VERBOSE" != no ] && log_daemon_msg "Starting MailiaM Server" "mailiam"
    do_start
    case "\$?" in
        0|1) [ "\$VERBOSE" != no ] && log_end_msg 0 ;;
        2)   [ "\$VERBOSE" != no ] && log_end_msg 1 ;;
    esac
    ;;
  stop)
    [ "\$VERBOSE" != no ] && log_daemon_msg "Stopping MailiaM Server" "mailiam"
    do_stop
    case "\$?" in
        0|1) [ "\$VERBOSE" != no ] && log_end_msg 0 ;;
        2)   [ "\$VERBOSE" != no ] && log_end_msg 1 ;;
    esac
    ;;
  status)
    status_of_proc "\$DAEMON" "mailiam" && exit 0 || exit \$?
    ;;
  restart)
    log_daemon_msg "Restarting MailiaM Server" "mailiam"
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
    echo "Usage: /etc/init.d/mailiam {start|stop|status|restart}" >&2
    exit 3
    ;;
esac

exit 0
EOF
    chmod +x /etc/init.d/mailiam
    update-rc.d mailiam defaults
    if [ "${_SKIP_START:-0}" -eq 0 ]; then
        service mailiam start
    fi
}

create_service_linux_openrc() {
    local _bin="$1" _config="$2" _env="$3" _user="$4"
    mkdir -p /etc/init.d
    cat > /etc/init.d/mailiam <<EOF
#!/sbin/openrc-run

name="MailiaM"
description="MailiaM Server"
command="${_bin}"
command_args="--config=${_config}"
command_background=yes
pidfile="/run/mailiam.pid"
retry="SIGINT/30/SIGKILL/5"

depend() {
    need net
}

start_pre() {
    if [ -r "${_env}" ]; then
        set -a
        . "${_env}"
        set +a
    fi
    export RUN_AS_USER=${_user}
    export RUN_AS_GROUP=${_user}
    ulimit -n 65536
}
EOF
    chmod +x /etc/init.d/mailiam
    rc-update add mailiam default
    if [ "${_SKIP_START:-0}" -eq 0 ]; then
        rc-service mailiam restart
    fi
}

create_service_freebsd() {
    local _bin="$1" _config="$2" _env="$3" _user="$4" _log_dir="$5"
    ensure mkdir -p /usr/local/etc/rc.d
    cat > /usr/local/etc/rc.d/mailiam <<EOF
#!/bin/sh

# PROVIDE: mailiam
# REQUIRE: NETWORKING LOGIN
# KEYWORD: shutdown

. /etc/rc.subr

name="mailiam"
rcvar="mailiam_enable"
desc="MailiaM Server"

load_rc_config \$name

: \${mailiam_enable:="NO"}
: \${mailiam_runas_user:="${_user}"}
: \${mailiam_runas_group:="${_user}"}
: \${mailiam_config:="${_config}"}
: \${mailiam_envfile:="${_env}"}
: \${mailiam_logfile:="${_log_dir}/mailiam.log"}
: \${mailiam_fdlimit:="65536"}

pidfile="/var/run/mailiam.pid"
procname="${_bin}"
command="/usr/sbin/daemon"
command_args="-f -o \${mailiam_logfile} -p \${pidfile} ${_bin} --config=\${mailiam_config}"
sig_stop="INT"
start_precmd="mailiam_precmd"

mailiam_precmd()
{
    # daemon(8) passes its environment through to the service
    if [ -r "\${mailiam_envfile}" ]; then
        set -a
        . "\${mailiam_envfile}"
        set +a
    fi

    # MailiaM binds its listeners as root, then setuid()s to this account
    export RUN_AS_USER="\${mailiam_runas_user}"
    export RUN_AS_GROUP="\${mailiam_runas_group}"

    ulimit -n "\${mailiam_fdlimit}"
}

run_rc_command "\$1"
EOF
    chmod +x /usr/local/etc/rc.d/mailiam
    sysrc mailiam_enable=YES
    if [ "${_SKIP_START:-0}" -eq 0 ]; then
        service mailiam stop > /dev/null 2>&1 || true
        service mailiam start
    fi
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

print_banner() {
    printf '%s' "$CLR_RED"
    cat <<'EOF'
 ███▄ ▄███▓ ▄▄▄       ██▓ ██▓     ██▓ ▄▄▄       ███▄ ▄███▓
▓██▒▀█▀ ██▒▒████▄    ▓██▒▓██▒    ▓██▒▒████▄    ▓██▒▀█▀ ██▒
▓██    ▓██░▒██  ▀█▄  ▒██▒▒██░    ▒██▒▒██  ▀█▄  ▓██    ▓██░
▒██    ▒██ ░██▄▄▄▄██ ░██░▒██░    ░██░░██▄▄▄▄██ ▒██    ▒██
▒██▒   ░██▒ ▓█   ▓██▒░██░░██████▒░██░ ▓█   ▓██▒▒██▒   ░██▒
░ ▒░   ░  ░ ▒▒   ▓▒█░░▓  ░ ▒░▓  ░░▓   ▒▒   ▓▒█░░ ▒░   ░  ░
░  ░      ░  ▒   ▒▒ ░ ▒ ░░ ░ ▒  ░ ▒ ░  ▒   ▒▒ ░░  ░      ░
░      ░     ░   ▒    ▒ ░  ░ ░    ▒ ░  ░   ▒   ░      ░
       ░         ░  ░ ░      ░  ░ ░        ░  ░       ░
EOF
    printf '%s\n' "$CLR_RESET"
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
    local _err=
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
        if [ -t 2 ]; then
            _curl_ui='--progress-bar'
        else
            _curl_ui='--silent --show-error'
        fi
        if [ -n "$_ciphersuites" ]; then
            downloader_run curl $_retry --proto '=https' --tlsv1.2 --ciphers "$_ciphersuites" $_curl_ui --fail --location "$1" --output "$2"
            _status=$?
        else
            echo "Warning: Not enforcing strong cipher suites for TLS, this is potentially less secure"
            if ! check_help_for "$3" curl --proto --tlsv1.2; then
                echo "Warning: Not enforcing TLS v1.2, this is potentially less secure"
                downloader_run curl $_retry $_curl_ui --fail --location "$1" --output "$2"
                _status=$?
            else
                downloader_run curl $_retry --proto '=https' --tlsv1.2 $_curl_ui --fail --location "$1" --output "$2"
                _status=$?
            fi
        fi
        downloader_fail "$_status" "$3"
        return $_status
    elif [ "$_dld" = wget ]; then
        if [ -t 2 ]; then
            _wget_ui=
        else
            _wget_ui='-q'
        fi
        if [ "$(wget -V 2>&1|head -2|tail -1|cut -f1 -d" ")" = "BusyBox" ]; then
            echo "Warning: using the BusyBox version of wget.  Not enforcing strong cipher suites for TLS or TLS v1.2, this is potentially less secure"
            downloader_run wget $_wget_ui "$1" -O "$2"
            _status=$?
        else
            get_ciphersuites_for_wget
            _ciphersuites="$RETVAL"
            if [ -n "$_ciphersuites" ]; then
                downloader_run wget $_wget_ui --https-only --secure-protocol=TLSv1_2 --ciphers "$_ciphersuites" "$1" -O "$2"
                _status=$?
            else
                echo "Warning: Not enforcing strong cipher suites for TLS, this is potentially less secure"
                if ! check_help_for "$3" wget --https-only --secure-protocol; then
                    echo "Warning: Not enforcing TLS v1.2, this is potentially less secure"
                    downloader_run wget $_wget_ui "$1" -O "$2"
                    _status=$?
                else
                    downloader_run wget $_wget_ui --https-only --secure-protocol=TLSv1_2 "$1" -O "$2"
                    _status=$?
                fi
            fi
        fi
        downloader_fail "$_status" "$3"
        return $_status
    else
        err "Unknown downloader"   # should not reach here
    fi
}

# TTY: native curl/wget bar on stderr. Piped: capture for 404.
downloader_run() {
    if [ -t 2 ]; then
        "$@"
    else
        _err=$("$@" 2>&1)
        return $?
    fi
}

downloader_fail() {
    _df_status="$1"
    _df_plat="$2"
    [ "$_df_status" -eq 0 ] && return 0
    if [ -n "${_err:-}" ]; then
        if echo "$_err" | grep -Eq '404|Not Found'; then
            err "❌  Binary for platform '$_df_plat' not found, this platform may be unsupported."
        fi
        echo "$_err" >&2
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
