# MailiaM Product Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the MailiaM rebrand of remaining wire names that `install.sh` / `scripts/test-install.sh` still cannot use because the binary, CI artifacts, default paths, and runtime env keys are still `stalwart` / `STALWART_*`.

**Architecture:** Keep the Cargo *package* name `stalwart` (`-p stalwart@0.16.25`). Change the *binary* name, release tarball member, FHS paths, Docker image layout, and runtime env keys to MailiaM. Dual-read old names so existing installs keep working. Do not rewrite store blob prefixes, OAuth key contexts, SPDX headers, historical `UPGRADING/` / `CHANGELOG.md`, or the GitHub repo slug unless the GitHub repo itself is renamed.

**Tech Stack:** POSIX `install.sh` (dash), `scripts/test-install.sh`, Rust (`crates/main`, `crates/common`, `crates/store`, `crates/jmap`, `crates/registry`), GitHub Actions (`.github/workflows/ci.yml`), `Dockerfile.build` / `Dockerfile*` / `docker-compose.yml`.

**Spec:** this plan. Prior UX spec: `docs/superpowers/specs/2026-10-19-install-sh-prompt-flow.md`. Session memory: `memory/mailiam-product-rename.md`.

## Global Constraints

- Cargo version stays `0.16.25`. Display/tag is `0.16.25-<suffix>` from `resources/RL_VERSION` via `env!("STALWART_VERSION")`. Do **not** put `-rlN` in `Cargo.toml`.
- Default features: `rocks` + `enterprise`. Pin crate: `-p stalwart@0.16.25` until/unless package name changes (it should not).
- SPDX `Stalwart Labs LLC <hello@stalw.art>` stays. Do not rewrite license headers.
- Dual license AGPL-3.0 / SELv2. Do not open upstream Stalwart issues/PRs (`AGENTS.md`).
- Commits local/RiseLabs unless asked to push. Conventional commits with a why-body.
- Targeted tests only. After shell edits: `sh scripts/test-install.sh`. After Rust env/path edits: `cargo test -p store@0.16.25 --lib` and any crate whose file you touched. Do not run full workspace tests.
- Existing DBs / env files / systemd units must keep working. Dual-read old names; write new names on fresh install.
- Do **not** rename store blob prefixes `STALWART_APP_`, `STALWART_SPAM_TRAIN_DATA.lz4`, `STALWART_SPAM_CLASSIFIER_MODEL.lz4` — they are on-disk keys.
- Do **not** rename OAuth HKDF contexts `stalwart-oauth-client-id-sw1`, `stalwart-oauth-token-sw1` — that invalidates tokens.
- GitHub clone URL is currently `Rezishon/stalwart`. Changing `_repo` default in `install.sh` **breaks downloads** unless that GitHub repo is actually renamed. Treat as a separate, explicit decision — default: leave `Rezishon/stalwart`.
- Historical docs (`UPGRADING/*.md`, old `CHANGELOG.md` entries) stay. New copy / new comments use MailiaM.

---

## Current state (2026-10-19, branch `deltachat-module`)

### Already done in `install.sh` / `scripts/test-install.sh`

User-facing brand is MailiaM. `sh scripts/test-install.sh` → `ALL PASSED`.

- Primary binary path: `/usr/local/bin/mailiam` with `stalwart` symlink (`ensure_bin_symlink`).
- Config dir: `/etc/mailiam` (FreeBSD `/usr/local/etc/mailiam`) with `/etc/stalwart` → `mailiam` symlink.
- Data/log: `/var/lib/mailiam`, `/var/log/mailiam` (FreeBSD data `/var/db/mailiam`).
- Env file: `mailiam.env`; falls back to `stalwart.env` if only the old file exists (`set_env_file`).
- systemd / init.d: `mailiam.service` / `/etc/init.d/mailiam`.
- FreeBSD rc.d: `/usr/local/etc/rc.d/mailiam` (`mailiam_enable`).
- Extract accepts archive member `mailiam` **or** `stalwart` (`extract_mailiam`).
- Service user default: `mailiam`.
- Banner / help / summaries say MailiaM.

### Left in those two files on purpose (this plan's work)

| What | Why it was left | New name |
|---|---|---|
| `download_url` → `stalwart-${_target}.tar.gz` | CI still ships `stalwart-…` | `mailiam-${_target}.tar.gz` |
| `_bin_legacy="${_bin_dir}/stalwart"` | detect old installs | keep as **legacy detect/symlink**, not brand |
| `detect_installed_bin` `command -v stalwart` | same | keep |
| `adopt_existing_layout` `/etc/stalwart`, `/var/lib/stalwart`, `/var/log/stalwart` | migrate old trees | keep as **read path** |
| `set_env_file` fallback `stalwart.env` | migrate | keep as **read path** |
| `Conflicts=… stalwart.service` | stop old unit | keep |
| Default `_repo="Rezishon/stalwart"` | real GitHub slug | **do not change** unless GitHub repo renamed |
| `STALWART_*` keys written by `write_env_file` | binary still reads `STALWART_*` | `MAILIAM_*` with fallback |
| SPDX header | legal | **never change** |

### Known mismatch (must fix with the artifact rename)

CI compress (`.github/workflows/ci.yml` Compress step) produces:

```
stalwart-x86_64-unknown-linux-musl.tar.gz
stalwart-aarch64-unknown-linux-musl.tar.gz
stalwart-armv7-unknown-linux-musleabihf.tar.gz
stalwart-x86_64-unknown-freebsd.tar.gz
stalwart-x86_64-pc-windows-msvc.zip
```

`install.sh` `artifact_target` + `download_url` ask for:

```
stalwart-x86_64-linux.tar.gz
stalwart-aarch64-linux.tar.gz
stalwart-armv7-linux.tar.gz
stalwart-x86_64-freebsd.tar.gz
```

Those two families **do not match**. Align both to **one** scheme while renaming:

- Preferred (short, already in `install.sh`): `mailiam-x86_64-linux.tar.gz` containing member `mailiam`.
- CI must emit that name (map `x86_64-unknown-linux-musl` → `x86_64-linux`, etc.), **or** `artifact_target` must emit the full rustc triple. Pick the short form. Update `scripts/test-install.sh` `download_url` assertions in the same commit.

Tarball member today: a single regular file named `stalwart` (from `crates/main` `[[bin]] name = "stalwart"`). After rename: member `mailiam`. `extract_mailiam` already accepts both.

### Env keys the binary actually reads (Rust)

`crates/store/src/registry/local.rs`:

- `STALWART_HOSTNAME`
- `STALWART_RECOVERY_MODE`
- `STALWART_RECOVERY_ADMIN`
- `STALWART_ROLE`
- `STALWART_PUSH_SHARD`
- `STALWART_PUBLIC_URL`
- `STALWART_HTTPS_PORT` (legacy fallback for public URL)

`crates/common/src/config/server/listener.rs`:

- `STALWART_RECOVERY_MODE_PORT` (default 8080)

`crates/common/src/config/telemetry.rs`:

- `STALWART_RECOVERY_MODE_LOG_LEVEL`

`crates/common/src/manager/boot.rs`:

- `CONFIG_PATH` (not STALWART-prefixed; leave)

`crates/common/src/network/listen.rs`:

- `RUN_AS_USER` / `RUN_AS_GROUP` (FreeBSD rc.d; leave)

Docker-only (not read by Rust):

- `STALWART_HEALTHCHECK_URL` — `Dockerfile`, `Dockerfile.build`, `Dockerfile.fdb`
- `STALWART_PATH` — `docker-compose.yml`, `Dockerfile.dev` (dead; binary uses `--config` / `CONFIG_PATH`)

### Env keys `install.sh` writes that Rust does **not** read

These are currently a no-op on first boot. `crates/common/src/manager/defaults.rs` hardcodes listener ports (`25/465/993/995/4190/443/8080`) and inserts `DeltaChat::default()` with no env:

- `STALWART_LISTEN_{SMTP,SUBMISSION,SUBMISSIONS,IMAP,POP3,SIEVE,HTTPS,HTTP}`
- `STALWART_TLS`
- `STALWART_DC_{IMAP,SMTP}_{HOST,PORT,SECURITY}` and `STALWART_DC_IC`

**Required as part of this rename:** either (A) wire `MAILIAM_*` (with `STALWART_*` fallback) into `insert_safe_defaults` so the installer ports/TLS/DC actually apply, or (B) stop writing them. Do **A**. Skipping this leaves the installer lying.

### Default on-disk paths still `stalwart` in the binary

New installs via `install.sh` already use `/var/lib/mailiam` etc., but first-boot registry defaults still point at old trees:

- `crates/common/src/manager/defaults.rs` TracerLog `path: "/var/log/stalwart"`, prefix `stalwart.log`
- `crates/jmap/src/registry/mapping/bootstrap.rs` `DEFAULT_DATA_PATH` `/var/lib/stalwart/` (`/var/db/stalwart/` on FreeBSD)
- `crates/registry/src/schema/structs_impl.rs` `Bootstrap` default data `/var/lib/stalwart/`, tracer `/var/log/stalwart/`

Docker:

- `Dockerfile.build` user `stalwart` uid 2000, `/etc/stalwart`, `/var/lib/stalwart`, `ENTRYPOINT /usr/local/bin/stalwart`
- `docker-compose.yml` service `stalwart-dev`, volume `stalwart-data`, `-c /var/lib/stalwart/config.json`

### Display strings still `Stalwart`

- `crates/common/src/lib.rs`: `USER_AGENT = "Stalwart/1.0.0"`, `DAEMON_NAME = concat!("Stalwart v", …)`, `PROD_ID = "-//Stalwart Labs LLC//Stalwart Server//EN"`
- `crates/store/src/build/registry.rs` bootstrap eprintln `"Stalwart bootstrap mode"`
- `crates/main/Cargo.toml` `description = "Stalwart Mail and Collaboration Server"` (package metadata; optional)

`STALWART_VERSION` rustc-env in `crates/common/build.rs` is compile-time, not a runtime env. Leave the *symbol* `STALWART_VERSION` unless you want a noisy grep; product display already uses `env!("STALWART_VERSION")`. Do not rename this in this pass.

### Helper already in `install.sh`

```sh
set_env_file() {
    _env_file="${_conf_dir}/mailiam.env"
    if [ ! -e "$_env_file" ] && [ -e "${_conf_dir}/stalwart.env" ]; then
        _env_file="${_conf_dir}/stalwart.env"
    fi
}
```

Do not duplicate. Dual-read of env *keys* belongs in Rust, not another shell helper.

---

## Dual-read rule (use everywhere a key is read)

```rust
fn env_mail(new: &str, old: &str) -> Result<String, std::env::VarError> {
    std::env::var(new).or_else(|_| std::env::var(old))
}
```

Put it next to the readers (small private fn in `crates/store/src/registry/local.rs` and the two `common` call sites — three copies is fine; do not add a new crate). Write **only** `MAILIAM_*` from `install.sh` `write_env_file`. Tests assert the new keys; add one fallback test that old keys still parse.

Key map:

| Old | New |
|---|---|
| `STALWART_HOSTNAME` | `MAILIAM_HOSTNAME` |
| `STALWART_PUBLIC_URL` | `MAILIAM_PUBLIC_URL` |
| `STALWART_HTTPS_PORT` | `MAILIAM_HTTPS_PORT` |
| `STALWART_RECOVERY_MODE` | `MAILIAM_RECOVERY_MODE` |
| `STALWART_RECOVERY_ADMIN` | `MAILIAM_RECOVERY_ADMIN` |
| `STALWART_RECOVERY_MODE_PORT` | `MAILIAM_RECOVERY_MODE_PORT` |
| `STALWART_RECOVERY_MODE_LOG_LEVEL` | `MAILIAM_RECOVERY_MODE_LOG_LEVEL` |
| `STALWART_ROLE` | `MAILIAM_ROLE` |
| `STALWART_PUSH_SHARD` | `MAILIAM_PUSH_SHARD` |
| `STALWART_LISTEN_*` | `MAILIAM_LISTEN_*` |
| `STALWART_TLS` | `MAILIAM_TLS` |
| `STALWART_DC_*` | `MAILIAM_DC_*` |
| `STALWART_HEALTHCHECK_URL` | `MAILIAM_HEALTHCHECK_URL` |

---

## File map

| File | Change |
|---|---|
| `crates/main/Cargo.toml` | `[[bin]] name = "mailiam"` only. Package name stays `stalwart`. |
| `crates/store/src/registry/local.rs` | Dual-read `MAILIAM_*` / `STALWART_*` |
| `crates/store/src/build/registry.rs` | Bootstrap message + `MAILIAM_RECOVERY_ADMIN` in the hint |
| `crates/common/src/config/server/listener.rs` | Dual-read recovery port |
| `crates/common/src/config/telemetry.rs` | Dual-read log level |
| `crates/common/src/manager/defaults.rs` | Read listen/TLS/DC env; default log path `/var/log/mailiam`; prefix `mailiam.log` |
| `crates/common/src/lib.rs` | `USER_AGENT` / `DAEMON_NAME` / `PROD_ID` → MailiaM (keep “Labs LLC” in PROD_ID if you want SPDX-aligned prod id; otherwise `MailiaM Server`) |
| `crates/jmap/src/registry/mapping/bootstrap.rs` | `DEFAULT_DATA_PATH` `/var/lib/mailiam/` (`/var/db/mailiam/` FreeBSD) |
| `crates/registry/src/schema/structs_impl.rs` | Bootstrap Default paths |
| `.github/workflows/ci.yml` | Copy `mailiam` / `mailiam.exe`; compress to short names `mailiam-x86_64-linux.tar.gz` etc. |
| `Dockerfile.build` | artifact `mailiam`; image bin `/usr/local/bin/mailiam`; user/paths `mailiam`; healthcheck env |
| `Dockerfile` / `Dockerfile.fdb` / `Dockerfile.dev` | same layout |
| `docker-compose.yml` | `mailiam-dev`, `/var/lib/mailiam`, `MAILIAM_RECOVERY_ADMIN` |
| `install.sh` | `download_url` `mailiam-${_target}.tar.gz`; `write_env_file` / help / upserts `MAILIAM_*` |
| `scripts/test-install.sh` | Match new keys, new tarball URL, keep legacy extract test |

---

### Task 1: Binary name `mailiam`

**Files:**
- Modify: `crates/main/Cargo.toml` (`[[bin]] name`)
- Modify: `Dockerfile.build` mv/COPY/ENTRYPOINT
- Modify: `.github/workflows/ci.yml` windows `stalwart.exe` → `mailiam.exe`; freebsd `artifacts/stalwart` → `artifacts/mailiam`
- Test: `scripts/test-install.sh` extract already accepts `mailiam`

**Interfaces:**
- Consumes: current `[[bin]] name = "stalwart"` producing `target/.../stalwart`
- Produces: cargo `-p stalwart` still; output binary `mailiam` / `mailiam.exe`

- [ ] **Step 1: Change only the bin name**

In `crates/main/Cargo.toml`:

```toml
[[bin]]
name = "mailiam"
path = "src/main.rs"
```

Leave `[package] name = "stalwart"`.

- [ ] **Step 2: Point CI / Docker at the new filename**

Windows job:

```yaml
mv ./target/${{matrix.target}}/release/mailiam.exe ./artifacts/mailiam.exe
```

FreeBSD job:

```sh
cp /tmp/target/release/mailiam artifacts/mailiam
```

`Dockerfile.build` builder:

```sh
mv /app/target/${TARGET}/release/mailiam /app/artifact/mailiam
# and foundationdb:
mv /app/target/${TARGET}/release/mailiam /app/artifact/mailiam-foundationdb
```

Runtime stages: `COPY … /usr/local/bin/mailiam`, `ENTRYPOINT ["/usr/local/bin/mailiam"]`.

- [ ] **Step 3: Targeted check**

```bash
cargo check -p stalwart@0.16.25
```

Expected: bin crate still named `stalwart`, binary `mailiam`.

- [ ] **Step 4: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(build): emit mailiam binary name

Installer already installs /usr/local/bin/mailiam. Cargo package
stays stalwart so -p stalwart@0.16.25 keeps working.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Release tarball names match `install.sh`

**Files:**
- Modify: `.github/workflows/ci.yml` Compress step
- Modify: `install.sh` `download_url`
- Modify: `scripts/test-install.sh` URL assertions

**Interfaces:**
- Consumes: Task 1 binary named `mailiam`
- Produces: GitHub release asset `mailiam-<short-target>.tar.gz` whose only member is `mailiam`

Short-target map (CI rustc triple → install.sh):

| rustc / artifact dir | short |
|---|---|
| `x86_64-unknown-linux-musl` | `x86_64-linux` |
| `aarch64-unknown-linux-musl` | `aarch64-linux` |
| `armv7-unknown-linux-musleabihf` | `armv7-linux` |
| `x86_64-unknown-freebsd` | `x86_64-freebsd` |
| `x86_64-pc-windows-msvc` | `x86_64-windows` (zip) |

- [ ] **Step 1: Failing test — new URL**

In `scripts/test-install.sh` change:

```sh
[ "$(download_url Rezishon/stalwart latest x86_64-linux)" = \
    "https://github.com/Rezishon/stalwart/releases/latest/download/mailiam-x86_64-linux.tar.gz" ] || fail url-latest
```

Keep owner/repo `Rezishon/stalwart` unless the GitHub repo is renamed.

- [ ] **Step 2: Run test, expect fail**

```bash
sh scripts/test-install.sh
```

Expected: `FAIL: url-latest`

- [ ] **Step 3: `download_url` in `install.sh`**

```sh
printf '%s\n' "${_src%/}/mailiam-${_target}.tar.gz"
# and the two github.com branches likewise
```

- [ ] **Step 4: CI Compress maps the dir name**

Replace the Compress `filename`/`archive_dir_name` logic with an explicit map, e.g.

```bash
short_target() {
    case "$1" in
        artifact-x86_64-unknown-linux-musl) echo x86_64-linux ;;
        artifact-aarch64-unknown-linux-musl) echo aarch64-linux ;;
        artifact-armv7-unknown-linux-musleabihf) echo armv7-linux ;;
        artifact-x86_64-unknown-freebsd) echo x86_64-freebsd ;;
        artifact-x86_64-pc-windows-msvc) echo x86_64-windows ;;
        *) echo "unknown artifact dir: $1" >&2; exit 1 ;;
    esac
}
# tar -czf "mailiam-$(short_target "$dir").tar.gz" mailiam
```

Do not silently keep producing `mailiam-x86_64-unknown-linux-musl.tar.gz` — installer will 404.

- [ ] **Step 5: Re-run `sh scripts/test-install.sh`** — `ALL PASSED`

- [ ] **Step 6: Commit** `fix(ci): ship mailiam-<short-target> archives`

---

### Task 3: Runtime env keys `MAILIAM_*` with `STALWART_*` fallback

**Files:**
- Modify: `crates/store/src/registry/local.rs`
- Modify: `crates/common/src/config/server/listener.rs`
- Modify: `crates/common/src/config/telemetry.rs`
- Modify: `crates/store/src/build/registry.rs` (eprintln hint)
- Modify: `install.sh` `write_env_file`, `apply_mode2_admin`, `seed_mode2_from_env`, `recovery_port`, help text, mode-2 upserts
- Modify: `scripts/test-install.sh` all `STALWART_*` assertions → `MAILIAM_*`; keep one upsert/read test that old keys still work if you add a rust unit, otherwise shell only tests what install writes

**Interfaces:**
- Consumes: `std::env::var("STALWART_…")` today
- Produces: `env_mail("MAILIAM_…", "STALWART_…")`; installer writes only new keys

- [ ] **Step 1: Failing shell test**

In `scripts/test-install.sh` `write_env_file` block, expect:

```sh
grep -q "^MAILIAM_HOSTNAME='mail.example.org'$" "$_tmp" || fail env-host
```

and stop expecting `STALWART_HOSTNAME=` in a **new** file. Keep a separate fixture that `read_env_key` still works on whatever key you pass (it is generic).

- [ ] **Step 2: Run `sh scripts/test-install.sh`** — fail `env-host`

- [ ] **Step 3: Dual-read in Rust**

`crates/store/src/registry/local.rs` `RegistryStoreInner::new`:

```rust
fn env_mail(new: &str, old: &str) -> Result<String, std::env::VarError> {
    std::env::var(new).or_else(|_| std::env::var(old))
}

let env_hostname = env_mail("MAILIAM_HOSTNAME", "STALWART_HOSTNAME")
    .ok()
    .filter(|h| !h.is_empty())
    .unwrap_or_else(|| { /* existing gethostname fallback */ });
```

Same for recovery mode/admin, role, push shard, public url, https port.

Listener recovery port:

```rust
env_mail("MAILIAM_RECOVERY_MODE_PORT", "STALWART_RECOVERY_MODE_PORT")
```

Telemetry:

```rust
env_mail("MAILIAM_RECOVERY_MODE_LOG_LEVEL", "STALWART_RECOVERY_MODE_LOG_LEVEL")
```

- [ ] **Step 4: Installer writes new keys**

`write_env_file`, upserts, help, comments: `MAILIAM_*`. Header comment: `MailiaM service`.

`seed_mode2_from_env` / `recovery_port` / `apply_mode2_admin`: read **new first, old fallback** (same as Rust). Small shell helper:

```sh
read_env_key_mail() { # file new old
    read_env_key "$1" "$2" || read_env_key "$1" "$3"
}
```

- [ ] **Step 5: `sh scripts/test-install.sh`** — `ALL PASSED`

- [ ] **Step 6: `cargo test -p store@0.16.25 --lib`** if you add a rust unit; otherwise skip.

- [ ] **Step 7: Commit** `feat(env): MAILIAM_* keys with STALWART_* fallback`

---

### Task 4: First-boot listeners / TLS / DeltaChat actually honor env

**Files:**
- Modify: `crates/common/src/manager/defaults.rs` (the `NetworkListener` loop ~437–468 and the `DeltaChat` insert ~517–550)
- Test: one focused test in that crate if a `#[cfg(test)]` already exists nearby; otherwise a tiny `#[test]` next to the helper that parses ports. Do not add a test framework.

**Interfaces:**
- Consumes: Task 3 `MAILIAM_LISTEN_*` / `MAILIAM_TLS` / `MAILIAM_DC_*` in the process env (EnvironmentFile already loaded by systemd before ExecStart)
- Produces: inserted `NetworkListener` bind ports and `DeltaChat` advertised endpoints matching installer choices. Port `0` skips that listener (already documented in `write_env_file`).

Current hardcoded loop:

```rust
(NetworkListenerProtocol::Smtp, "smtp", 25, false),
(NetworkListenerProtocol::Smtp, "submissions", 465, true),
(NetworkListenerProtocol::Imap, "imaps", 993, true),
(NetworkListenerProtocol::Pop3, "pop3s", 995, true),
(NetworkListenerProtocol::ManageSieve, "sieve", 4190, false),
(NetworkListenerProtocol::Http, "https", 443, true),
(NetworkListenerProtocol::Http, "http", 8080, false),
```

Installer defaults differ on several: IMAP 143 not 993, POP3 110 not 995, HTTP 80 not 8080, plus a submission 587 listener that defaults.rs **omits**.

- [ ] **Step 1: Helper**

```rust
fn env_port(new: &str, old: &str, default: u16) -> Option<u16> {
    let raw = std::env::var(new).or_else(|_| std::env::var(old)).ok()?;
    let p: u16 = raw.parse().ok()?;
    if p == 0 { None } else { Some(p) }
}
```

Use `Some(default)` when unset (not when set to 0).

- [ ] **Step 2: Drive the insert loop from env**

Map:

| tuple | env | install.sh default |
|---|---|---|
| smtp 25 | `MAILIAM_LISTEN_SMTP` | 25 |
| submission 587 **add this row** | `MAILIAM_LISTEN_SUBMISSION` | 587 |
| submissions 465 | `MAILIAM_LISTEN_SUBMISSIONS` | 465 |
| imap (plain or imaps) | `MAILIAM_LISTEN_IMAP` | 143 |
| pop3 | `MAILIAM_LISTEN_POP3` | 110 |
| sieve 4190 | `MAILIAM_LISTEN_SIEVE` | 4190 |
| https 443 | `MAILIAM_LISTEN_HTTPS` | 443 |
| http | `MAILIAM_LISTEN_HTTP` | 80 |

`MAILIAM_TLS` / `STALWART_TLS`: `1/true` → `use_tls = true`; `0/false` → `use_tls = false` and do not insert implicit-TLS variants the installer disabled. Match installer: TLS on → DC imap 993 / smtp 465 / ssl / ic=3; TLS off → 143 / 587 / plain / ic=0, unless `MAILIAM_DC_*` overrides.

DeltaChat insert: set advertised host/port/security/ic from `MAILIAM_DC_*` with `STALWART_DC_*` fallback, else hostname + TLS-derived defaults.

- [ ] **Step 3: `cargo check -p common@0.16.25`** (or the crate that owns `defaults.rs`)

- [ ] **Step 4: Commit** `feat(boot): honor MAILIAM_LISTEN_*/DC_* on first insert`

---

### Task 5: Default data/log paths and Docker layout

**Files:**
- Modify: `crates/common/src/manager/defaults.rs` TracerLog path/prefix
- Modify: `crates/jmap/src/registry/mapping/bootstrap.rs` `DEFAULT_DATA_PATH`
- Modify: `crates/registry/src/schema/structs_impl.rs` Bootstrap Default
- Modify: `Dockerfile.build` user, dirs, VOLUME, WORKDIR, CMD `--config /etc/mailiam/config.json`
- Modify: `Dockerfile`, `Dockerfile.fdb`, `Dockerfile.dev`, `docker-compose.yml`

**Interfaces:**
- Consumes: installer already creating `/var/lib/mailiam`
- Produces: first-boot Rocks path and tracer path under mailiam; Docker image matches

New paths:

| | Linux | FreeBSD |
|---|---|---|
| data | `/var/lib/mailiam/` | `/var/db/mailiam/` |
| log | `/var/log/mailiam/` | `/var/log/mailiam/` |
| config (docker CMD) | `/etc/mailiam/config.json` | `/usr/local/etc/mailiam/config.json` |

Keep reading old trees in `install.sh` `adopt_existing_layout`. Do not migrate Docker volume names in a running compose project without a note in the commit body.

Docker user: `mailiam` uid/gid 2000 (same numbers so existing volume ownership still matches if they only rename the account string — **if** you change the name but keep 2000, files stay accessible). Prefer keep uid 2000.

- [ ] **Step 1: Change the three Rust defaults**
- [ ] **Step 2: Docker files**
- [ ] **Step 3: `cargo check -p jmap@0.16.25` `-p registry@0.16.25` `-p common@0.16.25`**
- [ ] **Step 4: Commit** `feat(paths): default data/log under /var/{lib,log}/mailiam`

---

### Task 6: User-visible daemon strings

**Files:**
- Modify: `crates/common/src/lib.rs` `USER_AGENT`, `DAEMON_NAME`, `PROD_ID`
- Modify: `crates/store/src/build/registry.rs` bootstrap banner
- Optional: `crates/main/Cargo.toml` `description`

Leave `VERSION_PUBLIC = "1.0.0"`. Leave `env!("STALWART_VERSION")` identifier.

```rust
pub static USER_AGENT: &str = "MailiaM/1.0.0";
pub static DAEMON_NAME: &str = concat!("MailiaM v", env!("STALWART_VERSION"),);
pub static PROD_ID: &str = "-//RiseLabs//MailiaM Server//EN";
```

Confirm PROD_ID with the user if calendar interop against existing clients matters; changing iCalendar PRODID is visible but not a protocol break.

- [ ] **Step 1: Edit strings**
- [ ] **Step 2: `cargo check -p common@0.16.25`**
- [ ] **Step 3: Commit** `feat(brand): MailiaM USER_AGENT/DAEMON_NAME/PROD_ID`

---

### Task 7: Verify installer end-to-end against the new names

**Files:** none new. Drive `scripts/test-install.sh` plus a dry extract.

- [ ] **Step 1:** `sh scripts/test-install.sh` → `ALL PASSED`
- [ ] **Step 2:** Confirm `install.sh` still extracts a `stalwart` member (legacy tarball) **and** a `mailiam` member. Already covered by `extract_mailiam` tests; do not delete the legacy case.
- [ ] **Step 3:** `rg -n 'Stalwart|stalwart' install.sh scripts/test-install.sh` — remaining hits must be only: SPDX, GitHub slug `Rezishon/stalwart`, legacy detect/symlink/adopt paths, `Conflicts=stalwart.service`, `extract_mailiam` `stalwart|./stalwart` arm, `STALWART_*` as **fallback** reads (not writes). No `STALWART_*` in `write_env_file` output.
- [ ] **Step 4:** Commit only if step 3 found stragglers you fixed.

---

## Out of scope (do not do in this pass)

- SPDX-FileCopyrightText / license identifiers
- Cargo `[package] name = "stalwart"` / workspace `-p stalwart`
- `env!("STALWART_VERSION")` rustc-env name
- Store blob prefixes `STALWART_APP_`, `STALWART_SPAM_*`
- OAuth HKDF context strings
- Renaming GitHub repo `Rezishon/stalwart`
- Rewriting `UPGRADING/*.md` or old changelog entries
- Opening upstream Stalwart PRs
- Full workspace `cargo test`

## Done when

1. `sh scripts/test-install.sh` passes.
2. Fresh install writes `mailiam.env` with `MAILIAM_*` only.
3. Old `stalwart.env` + `STALWART_*` still boot.
4. CI would publish `mailiam-x86_64-linux.tar.gz` (and siblings) containing member `mailiam`.
5. First-boot listeners/DC match installer env (Task 4).
6. SPDX still says Stalwart Labs LLC.
