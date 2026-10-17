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
3. **Password Policy:** Bootstrap admin password must be at least 12 characters long if a custom credential is entered.
4. **Update Support:** Automatically detects existing installations and offers an in-place binary update without overwriting `.env`, `config.json`, or data stores.
5. **Flexible Release Sources:** Supports the default GitHub repo (`Rezishon/stalwart`), custom GitHub repos (`owner/repo`), custom base URLs (`https://...`), and direct local tarball archives (`/path/to/archive.tar.gz`).
6. **RiseLabs Target Mapping:** Maps system architectures to RiseLabs single-binary release artifact names (`x86_64-linux`, `aarch64-linux`, `armv7-linux`, `x86_64-freebsd`) instead of full rustup triples.
7. **Pruned Platform Code:** Drops dead macOS launchd and FoundationDB (`--fdb`) logic; focuses on Linux (`systemd`, `init.d`) and FreeBSD (`rc.d`).
8. **Unattended / CI Mode:** Supports non-interactive flags (`-y`, `--update`, `--repo`, `--version`, `--prefix`, `--hostname`, `--admin`, `--no-start`).

---

## 2. Interactive Flow & Prompts

### Step 1: Privilege & Dependency Verification
- Verify running as `root` (`id -u == 0`). If not, exit with error.
- Check required commands: `uname`, `mktemp`, `chmod`, `chown`, `mkdir`, `rm`, `tar`, `cp`, `hostname`, and either `curl` or `wget`.
- Check TTY: if stdin is not a TTY (e.g. `curl ... | sh`), automatically run in non-interactive default mode unless flags are passed.

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

### Step 8: Admin Bootstrap Credential
*(Skipped during update mode)*
- Prompt: `Admin bootstrap credential [username:password or 'random'] (Default: random):`
  - Default: `random`
  - Validation:
    - If `random` or empty: accepted.
    - If custom: must be in format `<username>:<password>`.
    - `<username>`: non-empty, alphanumeric / underscore / hyphens.
    - `<password>`: **minimum 12 characters** (strict policy).

### Step 9: Service Auto-Start
- Prompt: `Enable and start service now? [Y/n] (Default: Y):`
  - Default: `Y`
  - Validation: `y`, `yes`, `n`, `no` (case-insensitive).

---

## 3. Command Line Flags (Unattended Mode)

To support automation, CI, and scripted setups, the following flags bypass interactive prompts:

| Flag | Argument | Description |
|---|---|---|
| `-y`, `--yes`, `--non-interactive` | None | Run non-interactively using all default values. |
| `-u`, `--update` | None | Run in update mode: replaces binary and restarts service. |
| `--repo` | `<repo>` | Set GitHub repository (e.g. `Rezishon/stalwart`) or custom base URL. |
| `--version` | `<tag>` | Set release tag (e.g. `latest` or `v0.16.25-rl1`). |
| `--file` | `<path>` | Install directly from a local `.tar.gz` archive. |
| `--prefix` | `<path>` | Set installation prefix path. |
| `--user` | `<name>` | Set system service account name. |
| `--hostname` | `<host>` | Set server hostname (`STALWART_HOSTNAME`). |
| `--public-url` | `<url>` | Set public base URL (`STALWART_PUBLIC_URL`). |
| `--admin` | `<user:pass>`| Set initial admin credentials (password >= 12 chars). |
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
   - Test default input (`printf "\n\n\n\n\n" | sh install.sh`).
   - Test invalid inputs (bad hostname, short password < 12 chars, invalid choice).
   - Test update flow on existing install.
3. **Non-Interactive Flag Checks:**
   - Test `--help`.
   - Test `-y --prefix /tmp/test-stalwart --no-start` mock install.
