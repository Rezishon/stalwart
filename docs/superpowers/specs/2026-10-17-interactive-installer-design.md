# Interactive & Updatable Installer Design Spec

**Date:** 2026-10-17  
**Scope:** `install.sh`  
**Status:** Draft for Review  

---

## 1. Overview & Goals

`install.sh` is transformed into an interactive, validation-enforced, and update-capable installer for the RiseLabs Stalwart single-binary distribution.

### Key Objectives
1. **Interactive Prompting with Defaults:** Every prompt displays a sensible default in brackets (e.g. `[Default: ...]`). Pressing `Enter` accepts the default; typing a value overrides it.
2. **Strict Input Validation:** Inputs are validated inline with targeted error messages and loop back on invalid entry.
3. **Password Policy:** Bootstrap admin credential is either `random` (default) or custom `username:password`. Custom password must be at least 12 characters.
4. **Update Support:** Automatically detects existing installations and offers an in-place binary update without overwriting `.env`, `config.json`, or data stores.
5. **Flexible Release Sources:** Supports the default GitHub repo (`Rezishon/stalwart`), custom GitHub repos (`owner/repo`), custom base URLs (`https://...`), and direct local tarball archives (`/path/to/archive.tar.gz`).
6. **RiseLabs Target Mapping:** Maps system architectures to RiseLabs single-binary release artifact names (`x86_64-linux`, `aarch64-linux`, `armv7-linux`, `x86_64-freebsd`) instead of full rustup triples.
7. **Pruned Platform Code:** Drops dead macOS launchd and FoundationDB (`--fdb`) logic; focuses on Linux (`systemd`, `init.d`) and FreeBSD (`rc.d`).
8. **Unattended / CI Mode:** Supports non-interactive flags (`-y`, `--update`, `--repo`, `--version`, `--prefix`, `--hostname`, `--admin`, `--no-start`).
9. **Ports from env, not literals:** First-boot listeners, recovery HTTP bind, and DeltaChat advertised endpoints read `STALWART_*` env. Defaults match today’s numbers. `install.sh` only writes those keys. Do not have the installer write `config.json` listeners.

---

## 1.1 Binary contract (do this before `install.sh`)

Hardcoded ports live in `insert_safe_defaults` (`crates/common/src/manager/defaults.rs`), recovery bind (`listener.rs` `STALWART_RECOVERY_MODE_PORT` / 8080), and `DeltaChatSettings::default` (993/465). Replace the numbers with env, same defaults.

Listeners are **not** created in bootstrap/recovery. Env must already be in `stalwart.env` (systemd `EnvironmentFile`) so the first normal start after the wizard sees it. Recovery HTTP is the only bind that applies on first process start.

Helper: one `env_u16("STALWART_LISTEN_SMTP", 25)` (empty/unset → default; invalid → log and default). Port `0` skips that listener.

| Listener | Env | Default | `tls_implicit` |
|---|---|---|---|
| smtp | `STALWART_LISTEN_SMTP` | 25 | no |
| submission | `STALWART_LISTEN_SUBMISSION` | 587 | no |
| submissions | `STALWART_LISTEN_SUBMISSIONS` | 465 | yes |
| imaps | `STALWART_LISTEN_IMAP` | 993 | yes |
| pop3s | `STALWART_LISTEN_POP3` | 995 | yes |
| sieve | `STALWART_LISTEN_SIEVE` | 4190 | no |
| https | `STALWART_LISTEN_HTTPS` | 443 | yes |
| http | `STALWART_LISTEN_HTTP` | 8080 | no |

`STALWART_HTTPS_PORT` stays the legacy **public URL** fallback. Do not reuse it for listen 443.

- **587:** add a `submission` listener to the default set (missing today). Port from `STALWART_LISTEN_SUBMISSION`.
- **TLS:** `STALWART_TLS` (`1`/`true`/`0`/`false`, default true) → `use_tls` on every inserted listener. When false, `tls_implicit` is also false. No ACME/certs in env.
- **Recovery HTTP:** `STALWART_RECOVERY_MODE_PORT` if set, else `STALWART_LISTEN_HTTP`, else 8080.
- **DeltaChat insert** (`DeltaChat::default()` in `defaults.rs` and `DeltaChatSettings::default`):

| Field | Env | Default |
|---|---|---|
| imap host | `STALWART_DC_IMAP_HOST` | empty (later fill from primary domain) |
| imap port | `STALWART_DC_IMAP_PORT` | `STALWART_LISTEN_IMAP` or 993 |
| imap security | `STALWART_DC_IMAP_SECURITY` | `ssl` (`ssl`/`starttls`/`default`/`plain`) |
| smtp host | `STALWART_DC_SMTP_HOST` | empty |
| smtp port | `STALWART_DC_SMTP_PORT` | `STALWART_LISTEN_SUBMISSIONS` or 465 |
| smtp security | `STALWART_DC_SMTP_SECURITY` | `ssl` |
| `ic` | `STALWART_DC_IC` | `3` (`0`/`1`/`3`) |

WebUI can still change listeners and DeltaChat after first login. Env is first insert only (`count_object == 0`).

Implement binary + tests first. Then installer prompts/flags that write the same keys.

---

## 2. Interactive Flow & Prompts

### Step 1: Privilege & Dependency Verification
- Verify running as `root` (`id -u == 0`). If not, exit with error.
- Check required commands: `uname`, `mktemp`, `chmod`, `chown`, `mkdir`, `rm`, `tar`, `cp`, `hostname`, and either `curl` or `wget`.
- Check TTY:
  - No TTY and neither `-y` nor `--update`: **exit**. Print: rerun from a TTY or pass `-y` / `--update`. `curl | sh` must not overwrite a live server.
  - `-y` and binary exists: update only (mode 1). Never reconfigure or rewrite env.
  - `-y` and no binary: fresh install with defaults.

### Step 2: Architecture & Platform Detection
- Detect OS: `Linux` or `FreeBSD`. (Unsupported OS terminates with error).
- Detect CPU architecture:
  - `x86_64` / `amd64`
  - `aarch64` / `arm64`
  - `armv7` / `armv7l`
- Map to RiseLabs artifact target slug:
  - Linux `x86_64` → `x86_64-linux`
  - Linux `aarch64` → `aarch64-linux`
  - Linux `armv7` → `armv7-linux`
  - FreeBSD `x86_64` → `x86_64-freebsd`
  - Other platforms terminate with unsupported error.

### Step 3: Installation Mode Detection
Check if a `stalwart` binary already exists at `$PREFIX/bin/stalwart` (or default `/usr/local/bin/stalwart`):
- If detected:
  - Prompt: `Existing Stalwart installation detected. Choose action [1-3] (Default: 1):`
    - `1) Update binary only (preserves existing config, env, and database)`
    - `2) Reconfigure environment (re-prompts settings and updates stalwart.env)`
    - `3) Fresh install (overwrites binary and recreates stalwart.env)`
  - Validation: Must be `1`, `2`, or `3`.
  - If `1` (Update) is selected: Skips path, user, and config prompts; jumps directly to download source and service restart.

### Step 4: Download Source & Version
- **Source Prompt:** `Download source [GitHub repo, custom URL, or local file] (Default: Rezishon/stalwart):`
  - Default: `Rezishon/stalwart`
  - Validation:
    - If `owner/repo`: matches regex `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`.
    - If URL: starts with `http://` or `https://`.
    - If local file: path exists, is readable, and ends with `.tar.gz`.
- **Version Tag Prompt (if not local file):** `Release tag (Default: latest):`
  - Default: `latest`
  - Validation: `latest` or alphanumeric string with dots/dashes (e.g., `v0.16.25-rl1`).

### Step 5: Installation Paths
*(Skipped during update mode)*
- Prompt: `Installation prefix (Default: /usr/local [Standard FHS]):`
  - Default: `/usr/local`
  - Validation: Must be an absolute path starting with `/`. Forbidden paths: `/`, `/bin`, `/sbin`, `/lib`, `/usr`, `/dev`, `/proc`, `/sys`.
  - Path Resolution:
    - Standard `/usr/local`:
      - Bin: `/usr/local/bin`
      - Conf & Env: `/etc/stalwart` (FreeBSD: `/usr/local/etc/stalwart`)
      - Logs: `/var/log/stalwart`
      - Data: `/var/lib/stalwart` (FreeBSD: `/var/db/stalwart`)
    - Custom `$PREFIX`:
      - Bin: `$PREFIX/bin`
      - Conf & Env: `$PREFIX/etc`
      - Logs: `$PREFIX/logs`
      - Data: `$PREFIX/data`

### Step 6: System Service Account
*(Skipped during update mode)*
- Prompt: `System user account (Default: stalwart):`
  - Default: `stalwart`
  - Validation: POSIX username format `^[a-z_][a-z0-9_-]*$` and length <= 32 chars.

### Step 7: Network & Hostname Configuration
*(Skipped during update mode)*
- **Server Hostname:**
  - Default: Host FQDN via `hostname -f` (or fallback `hostname`, or `mail.local`).
  - Prompt: `Server hostname (Default: <DETECTED_HOSTNAME>):`
  - Validation: Valid RFC 1123 hostname or IPv4 address.
- **Public URL:**
  - Default: `https://<HOSTNAME>`
  - Prompt: `Public base URL (Default: https://<HOSTNAME>):`
  - Validation: Starts with `http://` or `https://` followed by valid hostname/IP and optional port.

### Step 8: Listen ports, TLS, DeltaChat advertise
*(Skipped during update mode)*

Prompt each listen port with the binary default. Validation: integer `0`–`65535`. `0` = do not create that listener. Duplicate non-zero ports: one-line error, re-prompt.

| Prompt | Env written |
|---|---|
| `SMTP port (Default: 25):` | `STALWART_LISTEN_SMTP` |
| `Submission port (Default: 587):` | `STALWART_LISTEN_SUBMISSION` |
| `Submissions (SMTPS) port (Default: 465):` | `STALWART_LISTEN_SUBMISSIONS` |
| `IMAP port (Default: 993):` | `STALWART_LISTEN_IMAP` |
| `POP3 port (Default: 995):` | `STALWART_LISTEN_POP3` |
| `ManageSieve port (Default: 4190):` | `STALWART_LISTEN_SIEVE` |
| `HTTPS port (Default: 443):` | `STALWART_LISTEN_HTTPS` |
| `HTTP port (Default: 8080):` | `STALWART_LISTEN_HTTP` |

- **TLS:** `Enable TLS on listeners? [Y/n] (Default: Y):` → `STALWART_TLS=true` or `false`. No cert/ACME prompts.
- **DeltaChat advertise** (defaults follow listen ports + server hostname):
  - `DeltaChat IMAP host (Default: <HOSTNAME>):` → `STALWART_DC_IMAP_HOST`
  - `DeltaChat IMAP port (Default: <LISTEN_IMAP>):` → `STALWART_DC_IMAP_PORT`
  - `DeltaChat IMAP security [ssl/starttls/default/plain] (Default: ssl):` → `STALWART_DC_IMAP_SECURITY`
  - `DeltaChat SMTP host (Default: <HOSTNAME>):` → `STALWART_DC_SMTP_HOST`
  - `DeltaChat SMTP port (Default: <LISTEN_SUBMISSIONS>):` → `STALWART_DC_SMTP_PORT`
  - `DeltaChat SMTP security [ssl/starttls/default/plain] (Default: ssl):` → `STALWART_DC_SMTP_SECURITY`
  - `DeltaChat certificate checks [0/1/3] (Default: 3):` → `STALWART_DC_IC`
- Write only keys the operator overrode **or** always write the full set with defaults. Prefer always write the full set so the binary does not depend on compiled defaults after install.
- Do not write `config.json`. Do not set `STALWART_RECOVERY_MODE`.

### Step 9: Admin Bootstrap Credential
*(Skipped during update mode)*
- Prompt: `Admin bootstrap credential [username:password or 'random'] (Default: random):`
  - Default: `random` (Enter or empty).
  - Split: first `:` only. Username is the left side; password is everything after the first colon (colons inside the password are allowed).
  - Validation:
    - If `random` or empty: accepted. Do not write `STALWART_RECOVERY_ADMIN`; Stalwart prints a generated password to the service logs.
    - If custom: must be `<username>:<password>`.
    - `<username>`: non-empty, matches `^[A-Za-z0-9_-]+$`.
    - `<password>`: **at least 12 characters**. Longer is allowed. No other complexity rules.
  - On failure (interactive): print a one-line error and re-prompt. Do not continue.
    - Missing `:`: `Credential must be username:password or 'random'.`
    - Empty or invalid username: `Username must be alphanumeric, underscore, or hyphen.`
    - Password shorter than 12: `Password must be at least 12 characters.`
  - On failure (`--admin`): exit non-zero with the same one-line error. Do not fall back to `random`.
  - On success (custom): write `STALWART_RECOVERY_ADMIN=<username>:<password>` into `stalwart.env`.

### Step 10: Service Auto-Start
- Prompt: `Enable and start service now? [Y/n] (Default: Y):`
  - Default: `Y`
  - Validation: `y`, `yes`, `n`, `no` (case-insensitive).

---

## 3. Command Line Flags (Unattended Mode)

To support automation, CI, and scripted setups, the following flags bypass interactive prompts:

| Flag | Argument | Description |
|---|---|---|
| `-y`, `--yes`, `--non-interactive` | None | Run non-interactively using all default values (admin = `random`). |
| `-u`, `--update` | None | Run in update mode: replaces binary and restarts service. |
| `--repo` | `<repo>` | Set GitHub repository (e.g. `Rezishon/stalwart`) or custom base URL. |
| `--version` | `<tag>` | Set release tag (e.g. `latest` or `v0.16.25-rl1`). |
| `--file` | `<path>` | Install directly from a local `.tar.gz` archive. |
| `--prefix` | `<path>` | Set installation prefix path. |
| `--user` | `<name>` | Set system service account name. |
| `--hostname` | `<host>` | Set server hostname (`STALWART_HOSTNAME`). |
| `--public-url` | `<url>` | Set public base URL (`STALWART_PUBLIC_URL`). |
| `--admin` | `<user:pass>` | Set custom admin credentials. Password must be at least 12 characters. Omit for `random`. |
| `--smtp-port` | `<n>` | `STALWART_LISTEN_SMTP` (default 25). |
| `--submission-port` | `<n>` | `STALWART_LISTEN_SUBMISSION` (default 587). |
| `--submissions-port` | `<n>` | `STALWART_LISTEN_SUBMISSIONS` (default 465). |
| `--imap-port` | `<n>` | `STALWART_LISTEN_IMAP` (default 993). |
| `--pop3-port` | `<n>` | `STALWART_LISTEN_POP3` (default 995). |
| `--sieve-port` | `<n>` | `STALWART_LISTEN_SIEVE` (default 4190). |
| `--https-port` | `<n>` | `STALWART_LISTEN_HTTPS` (default 443). Not `STALWART_HTTPS_PORT`. |
| `--http-port` | `<n>` | `STALWART_LISTEN_HTTP` (default 8080). |
| `--tls` / `--no-tls` | None | `STALWART_TLS=true` / `false`. Default `--tls`. |
| `--dc-imap-host` | `<host>` | `STALWART_DC_IMAP_HOST`. |
| `--dc-imap-port` | `<n>` | `STALWART_DC_IMAP_PORT`. |
| `--dc-imap-security` | `<s>` | `STALWART_DC_IMAP_SECURITY`. |
| `--dc-smtp-host` | `<host>` | `STALWART_DC_SMTP_HOST`. |
| `--dc-smtp-port` | `<n>` | `STALWART_DC_SMTP_PORT`. |
| `--dc-smtp-security` | `<s>` | `STALWART_DC_SMTP_SECURITY`. |
| `--dc-ic` | `0\|1\|3` | `STALWART_DC_IC`. |
| `--no-start` | None | Do not start or restart the service after installation. |
| `-h`, `--help` | None | Print usage instructions and exit. |

---

## 4. Execution Details & Safety

1. **Atomic Binary Replacement:**
   When updating an existing binary, the old executable is backed up to `${bin_file}.bak` before copy. If copy fails, the backup is restored.
2. **Configuration Protection:**
   Existing `stalwart.env` is never overwritten during an update unless reconfigure mode (`2`) or fresh install (`3`) is explicitly chosen.
3. **Download URL Resolution:**
   - GitHub repo:
     - `latest`: `https://github.com/${repo}/releases/latest/download/${component}-${target}.tar.gz`
     - Tag: `https://github.com/${repo}/releases/download/${tag}/${component}-${target}.tar.gz`
   - Custom URL:
     - `${custom_url}/${component}-${target}.tar.gz`
4. **Permissions Enforcement:**
   - Service account created with disabled shell (`/usr/sbin/nologin`) and no home directory (`-M -r`).
   - Binaries: `0755 root:root`.
   - Directories (`conf`, `logs`, `data`): `0750 stalwart:stalwart`.
   - Environment file: `0640 root:stalwart`.

---

## 5. Verification Plan

1. **Syntax & Style Validation:**
   - Run `shellcheck install.sh` (or `sh -n install.sh`).
2. **Interactive Unit Checks (simulated via stdin / subshell):**
   - Test default input (`printf "\n\n\n\n\n" | sh install.sh`) uses `random`.
   - Test invalid inputs (bad hostname, custom password of 11 chars, custom password of 12 chars accepted, invalid choice).
   - Test `--admin admin:short` exits non-zero; `--admin admin:twelvechars1` is accepted.
   - Test update flow on existing install.
3. **Non-Interactive Flag Checks:**
   - Test `--help`.
   - Test `-y --prefix /tmp/test-stalwart --no-start` mock install (admin stays `random`).
   - Test listen flags write `STALWART_LISTEN_*` / `STALWART_TLS` / `STALWART_DC_*` into env.
   - Binary: `insert_safe_defaults` uses env ports; 587 listener exists; `STALWART_LISTEN_*=0` skips; recovery bind follows `STALWART_LISTEN_HTTP`; DeltaChat default reads `STALWART_DC_*`.
   - Piped `sh install.sh` with no `-y` exits non-zero.
