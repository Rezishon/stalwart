# Interactive Installer + First-Insert Ports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Binary first-insert of listeners and DeltaChat reads `STALWART_*` env (defaults unchanged); `install.sh` writes those keys via prompts/flags.

**Architecture:** Env is a seed, not runtime config. `insert_safe_defaults` (`count_object == 0`) and recovery HTTP bind read env. After insert, WebUI/`config.json` owns listeners and DeltaChat. Installer never writes listener JSON. `DeltaChat::default` / `DeltaChatSettings::default` stay compiled numbers so serde and unit tests do not touch process env.

**Tech Stack:** Rust (`crates/common`, `crates/deltachat` only as consumer of registry defaults), POSIX `sh` (`install.sh`), `scripts/test-install.sh`.

**Spec:** `docs/superpowers/specs/2026-10-17-interactive-installer-design.md`

## Global Constraints

- Binary + tests before `install.sh` behavior that depends on those env keys.
- Env keys and defaults exactly as spec §1.1. `STALWART_HTTPS_PORT` is public-URL fallback only.
- Port `0` skips that listener. Invalid/empty env → default (log once, do not panic).
- Do not read env inside `impl Default`. Seed at insert only.
- Do not add crates. Do not write `config.json` from the installer.
- Do not set `STALWART_RECOVERY_MODE` on a normal install.
- Linux + FreeBSD only. Drop macOS/`--fdb` from `install.sh`.
- `INSTALL_TEST=1` already guards `main` at the bottom of `install.sh`. Keep it.
- Targeted tests only (`cargo test -p common env_u16`, `cargo test -p common default_listener`, `sh scripts/test-install.sh`). No full workspace test.
- English comments. Clean, DRY, KISS. One helper per parse kind.
- Pipe rule: no TTY and no `-y`/`--update` → exit. `-y` + binary exists → update only.

## Done gate (every task)

After tests pass, before commit, three reviews. Task is not done if any fails.

1. **Security** — no secrets in logs/`say`; env assignments cannot become shell; no `http://` tarball; no listener JSON; port `0` does not bind all interfaces as port 0 by accident (skip, do not bind `:0`).
2. **Stalwart expert** — first-insert only; recovery vs post-wizard listeners; `STALWART_HTTPS_PORT` not reused; 587 added as `submission` not `submissions`; hostname env still every-start, ports not.
3. **Clean / KISS / DRY** — no extra files if a function fits; no `Default` reading env; validators shared by prompt and flags.

## File map

| File | Role |
|---|---|
| `crates/common/src/manager/defaults.rs` | `env_u16_from` / `env_bool_from` / `env_str_from`; `default_listener_specs`; seed DeltaChat at insert |
| `crates/common/src/config/server/listener.rs` | recovery bind: `STALWART_RECOVERY_MODE_PORT` else `STALWART_LISTEN_HTTP` else 8080 |
| `crates/registry/src/schema/structs_impl.rs` | **Do not** change `DeltaChat::default` (keep 993/465) |
| `crates/deltachat/src/config.rs` | **Do not** change `DeltaChatSettings::default` compiled ports |
| `install.sh` | validators, flags, prompts, `write_env_file`, TTY rule |
| `scripts/test-install.sh` | already exists; extend, do not replace |

## Roadmap

```
1. Env parse helpers (pure, no process env in tests)
2. Listener specs from env + 587 + TLS + skip 0
3. Recovery HTTP bind
4. DeltaChat seed at insert
5. install.sh helpers (make existing test-install.sh pass)
6. write_env_file + flags for ports/TLS/DC
7. TTY / mode / prompts
```

---

### Task 1: Env parse helpers

**Files:**
- Modify: `crates/common/src/manager/defaults.rs` (append helpers + `#[cfg(test)]` at end of file)

**Interfaces:**
- Produces:
  ```rust
  pub(crate) fn env_u16_from(raw: Option<&str>, default: u16) -> u16
  pub(crate) fn env_bool_from(raw: Option<&str>, default: bool) -> bool
  pub(crate) fn env_str_from(raw: Option<&str>, default: &str) -> String
  pub(crate) fn env_u16(key: &str, default: u16) -> u16 {
      env_u16_from(std::env::var(key).ok().as_deref(), default)
  }
  ```
- `env_u16_from`: `None` / `""` → default. Parse `u16`; fail → default. `"0"` → `0`.
- `env_bool_from`: `1`/`true`/`TRUE`/`yes` → true; `0`/`false`/`FALSE`/`no` → false; else default.
- `env_str_from`: `None` / `""` → `default.to_string()`; else trimmed string.

- [ ] **Step 1: Write the failing tests** at the bottom of `defaults.rs`:

```rust
#[cfg(test)]
mod env_parse_tests {
    use super::{env_bool_from, env_str_from, env_u16_from};

    #[test]
    fn env_u16_default_on_empty() {
        assert_eq!(env_u16_from(None, 25), 25);
        assert_eq!(env_u16_from(Some(""), 25), 25);
        assert_eq!(env_u16_from(Some("nope"), 25), 25);
    }

    #[test]
    fn env_u16_zero_and_value() {
        assert_eq!(env_u16_from(Some("0"), 25), 0);
        assert_eq!(env_u16_from(Some("587"), 25), 587);
        assert_eq!(env_u16_from(Some("65535"), 25), 65535);
        assert_eq!(env_u16_from(Some("65536"), 25), 25);
    }

    #[test]
    fn env_bool_and_str() {
        assert!(env_bool_from(Some("true"), false));
        assert!(!env_bool_from(Some("0"), true));
        assert!(env_bool_from(None, true));
        assert_eq!(env_str_from(Some(" mail.example "), "x"), "mail.example");
        assert_eq!(env_str_from(Some(""), "ssl"), "ssl");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p common env_u16_default_on_empty --lib`
Expected: FAIL compile (`env_u16_from` not found)

- [ ] **Step 3: Write minimal implementation** in `defaults.rs` (same file, above the listener loop is fine; keep functions `pub(crate)`):

```rust
pub(crate) fn env_u16_from(raw: Option<&str>, default: u16) -> u16 {
    let Some(s) = raw.map(str::trim).filter(|s| !s.is_empty()) else {
        return default;
    };
    s.parse().unwrap_or_else(|_| {
        trc::event!(
            Server(trc::ServerEvent::Startup),
            Details = format!("invalid port {s:?}, using {default}")
        );
        default
    })
}

pub(crate) fn env_bool_from(raw: Option<&str>, default: bool) -> bool {
    match raw.map(str::trim) {
        Some("1" | "true" | "TRUE" | "yes" | "YES") => true,
        Some("0" | "false" | "FALSE" | "no" | "NO") => false,
        Some(other) if !other.is_empty() => {
            trc::event!(
                Server(trc::ServerEvent::Startup),
                Details = format!("invalid bool {other:?}, using {default}")
            );
            default
        }
        _ => default,
    }
}
```

If `ServerEvent::Startup` is the wrong event for parse noise, use `eprintln!` once — do not panic, do not skip the default. Tests still assert the returned number only.

pub(crate) fn env_str_from(raw: Option<&str>, default: &str) -> String {
    match raw.map(str::trim).filter(|s| !s.is_empty()) {
        Some(s) => s.to_string(),
        None => default.to_string(),
    }
}

pub(crate) fn env_u16(key: &str, default: u16) -> u16 {
    env_u16_from(std::env::var(key).ok().as_deref(), default)
}

pub(crate) fn env_bool(key: &str, default: bool) -> bool {
    env_bool_from(std::env::var(key).ok().as_deref(), default)
}

pub(crate) fn env_str(key: &str, default: &str) -> String {
    env_str_from(std::env::var(key).ok().as_deref(), default)
}
```

- [ ] **Step 4: Run tests**

Run: `cargo test -p common env_parse_tests --lib`
Expected: PASS

- [ ] **Step 5: Three-agent review, then commit**

```bash
git add crates/common/src/manager/defaults.rs
git commit -m "feat(common): parse STALWART listen env as u16/bool/str"
```

---

### Task 2: Listener specs from env

**Files:**
- Modify: `crates/common/src/manager/defaults.rs` lines 437–467

**Interfaces:**
- Consumes: `env_u16_from`, `env_bool_from` from Task 1
- Produces: `default_listener_specs_from(get) -> Vec<(NetworkListenerProtocol, &'static str, u16, bool)>` (protocol, name, port, tls_implicit). Insert iterates that. No `ListenerSpec` type. No `default_listener_specs()` wrapper.
- Table (port from env, compiled default if unset):

| name | env | default | protocol | tls_implicit |
|---|---|---|---|---|
| smtp | `STALWART_LISTEN_SMTP` | 25 | Smtp | false |
| submission | `STALWART_LISTEN_SUBMISSION` | 587 | Smtp | false |
| submissions | `STALWART_LISTEN_SUBMISSIONS` | 465 | Smtp | true |
| imaps | `STALWART_LISTEN_IMAP` | 993 | Imap | true |
| pop3s | `STALWART_LISTEN_POP3` | 995 | Pop3 | true |
| sieve | `STALWART_LISTEN_SIEVE` | 4190 | ManageSieve | false |
| https | `STALWART_LISTEN_HTTPS` | 443 | Http | true |
| http | `STALWART_LISTEN_HTTP` | 8080 | Http | false |

- `STALWART_TLS` default true → `use_tls` on insert. If false, force `tls_implicit = false`.
- Port `0`: omit from the vec (do not insert, do not bind `:0`).
- Existing listeners (`count_object != 0`): do not read env, do not update.

- [ ] **Step 1: Write the failing tests** in the same `#[cfg(test)]` module:

```rust
    #[test]
    fn default_listeners_include_submission_587() {
        let specs = default_listener_specs_from(|k| match k {
            "STALWART_TLS" => Some("true".into()),
            _ => None,
        });
        assert!(specs.iter().any(|s| s.1 == "submission" && s.2 == 587));
        assert!(specs.iter().any(|s| s.1 == "submissions" && s.2 == 465));
        assert_eq!(specs.len(), 8);
    }

    #[test]
    fn default_listeners_skip_zero_and_honor_tls_off() {
        let specs = default_listener_specs_from(|k| match k {
            "STALWART_LISTEN_POP3" => Some("0".into()),
            "STALWART_LISTEN_HTTP" => Some("9080".into()),
            "STALWART_TLS" => Some("false".into()),
            _ => None,
        });
        assert!(!specs.iter().any(|s| s.1 == "pop3s"));
        let http = specs.iter().find(|s| s.1 == "http").unwrap();
        assert_eq!(http.2, 9080);
        assert!(specs.iter().all(|s| !s.3));
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p common default_listeners_include_submission_587 --lib`
Expected: FAIL compile

- [ ] **Step 3: Implement `default_listener_specs_from` and replace the hardcoded tuple loop**

```rust
pub(crate) fn default_listener_specs_from(
    get: impl Fn(&str) -> Option<String>,
) -> Vec<(NetworkListenerProtocol, &'static str, u16, bool)> {
    let use_tls = env_bool_from(get("STALWART_TLS").as_deref(), true);
    const ROWS: &[(NetworkListenerProtocol, &str, &str, u16, bool)] = &[
        (NetworkListenerProtocol::Smtp, "smtp", "STALWART_LISTEN_SMTP", 25, false),
        (NetworkListenerProtocol::Smtp, "submission", "STALWART_LISTEN_SUBMISSION", 587, false),
        (NetworkListenerProtocol::Smtp, "submissions", "STALWART_LISTEN_SUBMISSIONS", 465, true),
        (NetworkListenerProtocol::Imap, "imaps", "STALWART_LISTEN_IMAP", 993, true),
        (NetworkListenerProtocol::Pop3, "pop3s", "STALWART_LISTEN_POP3", 995, true),
        (NetworkListenerProtocol::ManageSieve, "sieve", "STALWART_LISTEN_SIEVE", 4190, false),
        (NetworkListenerProtocol::Http, "https", "STALWART_LISTEN_HTTPS", 443, true),
        (NetworkListenerProtocol::Http, "http", "STALWART_LISTEN_HTTP", 8080, false),
    ];
    ROWS.iter()
        .filter_map(|&(protocol, name, key, default, tls_implicit)| {
            let port = env_u16_from(get(key).as_deref(), default);
            if port == 0 {
                return None;
            }
            Some((protocol, name, port, use_tls && tls_implicit))
        })
        .collect()
}
```

Insert loop: `for (protocol, name, port, tls_implicit) in default_listener_specs_from(|k| std::env::var(k).ok())`. Bind `[::]:{port}`. `use_tls` comes from that same `get` (`STALWART_TLS` inside `default_listener_specs_from`). Do not call `env_bool("STALWART_TLS")` a second time. No `std::env::set_var` in tests.

- [ ] **Step 4: Run tests**

Run: `cargo test -p common env_parse_tests --lib`
Expected: PASS

- [ ] **Step 5: Three-agent review, then commit**

```bash
git add crates/common/src/manager/defaults.rs
git commit -m "feat(common): seed NetworkListener ports from STALWART_LISTEN_* env"
```

---

### Task 3: Recovery HTTP bind

**Files:**
- Modify: `crates/common/src/config/server/listener.rs` lines 69–75
- Modify: `crates/common/src/manager/boot.rs` lines 168–179 (replace hardcoded `"Port 8080 is open…"` with the resolved `recovery_http_port()`)

**Interfaces:**
- Helpers stay in `defaults.rs`. `listener.rs` calls `crate::manager::defaults::recovery_http_port()`. No extra file. No duplicate parser. No `mod.rs` re-export.

- Produces: recovery bind port as above. Port `0` for recovery is invalid → 8080 (must bind something for bootstrap UI).

- [ ] **Step 1: Failing test** in `listener.rs` or keep pure function in `defaults.rs`:

```rust
    #[test]
    fn recovery_http_port_fallback() {
        assert_eq!(recovery_http_port_from(None, None), 8080);
        assert_eq!(recovery_http_port_from(Some("9090"), Some("8080")), 9090);
        assert_eq!(recovery_http_port_from(None, Some("9080")), 9080);
        assert_eq!(recovery_http_port_from(Some("0"), None), 8080);
    }
```

```rust
pub(crate) fn recovery_http_port_from(recovery: Option<&str>, listen_http: Option<&str>) -> u16 {
    let p = env_u16_from(recovery, env_u16_from(listen_http, 8080));
    if p == 0 { 8080 } else { p }
}
```

Put this next to the other helpers in `defaults.rs`. `listener.rs` calls `crate::manager::defaults::recovery_http_port()` which reads env.

- [ ] **Step 2: Run to fail**

Run: `cargo test -p common recovery_http_port_fallback --lib`
Expected: FAIL compile

- [ ] **Step 3: Implement helper in `defaults.rs`. `recovery_http_port()` must remap `0` to `8080` (same as `recovery_http_port_from`). `listener.rs` calls `crate::manager::defaults::recovery_http_port()` only — never pass port `0` into `SocketAddr`.**

- [ ] **Step 4: Run** `cargo test -p common recovery_http_port_fallback --lib` — PASS

- [ ] **Step 5: Review ×3, commit**

```bash
git add crates/common/src/manager/defaults.rs crates/common/src/config/server/listener.rs crates/common/src/manager/boot.rs
git commit -m "feat(common): recovery HTTP port from STALWART_LISTEN_HTTP"
```

---

### Task 4: DeltaChat seed at insert

**Files:**
- Modify: `crates/common/src/manager/defaults.rs` lines 542–549 (`DeltaChat::default()` then insert)
- Do **not** edit `structs_impl.rs` `impl Default for DeltaChat`
- Do **not** edit `crates/deltachat/src/config.rs` `DeltaChatSettings::default`

**Interfaces:**
- Consumes: `env_u16`, `env_str`
- Produces:
  ```rust
  pub(crate) fn delta_chat_from_env() -> DeltaChat
  ```
  Start from `DeltaChat::default()`, then overlay:

| field | env | default |
|---|---|---|
| imap_host | `STALWART_DC_IMAP_HOST` | `""` |
| imap_port (`u64`) | `STALWART_DC_IMAP_PORT` else `STALWART_LISTEN_IMAP` else 993 |
| imap_security | `STALWART_DC_IMAP_SECURITY` | `ssl` — allow only `ssl` `starttls` `default` `plain`, else `ssl` |
| smtp_host | `STALWART_DC_SMTP_HOST` | `""` |
| smtp_port (`u64`) | `STALWART_DC_SMTP_PORT` else `STALWART_LISTEN_SUBMISSIONS` else 465 |
| smtp_security | `STALWART_DC_SMTP_SECURITY` | `ssl` |
| certificate_checks | `STALWART_DC_IC` | `3` — allow only `0` `1` `3`, else `3` |

Only used when inserting a **new** DeltaChat object (the `else` branch). Existing object path stays domain_id fill only.

- [ ] **Step 1: Failing test**

```rust
    #[test]
    fn delta_chat_from_env_overlays_ports() {
        let dc = delta_chat_from_get(|k| match k {
            "STALWART_DC_IMAP_PORT" => Some("1993".into()),
            "STALWART_DC_IC" => Some("1".into()),
            "STALWART_DC_IMAP_HOST" => Some("mail.example.org".into()),
            _ => None,
        });
        assert_eq!(dc.imap_port, 1993u64);
        assert_eq!(dc.certificate_checks, "1");
        assert_eq!(dc.imap_host, "mail.example.org");
        assert_eq!(dc.smtp_port, 465u64);
    }

    #[test]
    fn delta_chat_from_env_rejects_bad_security() {
        let dc = delta_chat_from_get(|k| match k {
            "STALWART_DC_IMAP_SECURITY" => Some("bogus".into()),
            "STALWART_DC_IC" => Some("9".into()),
            _ => None,
        });
        assert_eq!(dc.imap_security, "ssl");
        assert_eq!(dc.certificate_checks, "3");
    }
```

- [ ] **Step 2: Run to fail** — `cargo test -p common delta_chat_from_env_overlays_ports --lib`

- [ ] **Step 3: Implement `delta_chat_from_get` / `delta_chat_from_env`; replace `let mut dc = DeltaChat::default();` in the insert-else branch with `let mut dc = delta_chat_from_env();` then keep domain_id fill.**

Inline the two allow-lists in `delta_chat_from_get` (no named `dc_security` / `dc_ic` helpers):

```rust
imap_security: match get("STALWART_DC_IMAP_SECURITY").as_deref().map(str::trim) {
    Some(s @ ("ssl" | "starttls" | "default" | "plain")) => s.to_string(),
    _ => "ssl".into(),
},
certificate_checks: match get("STALWART_DC_IC").as_deref().map(str::trim) {
    Some(s @ ("0" | "1" | "3")) => s.to_string(),
    _ => "3".into(),
},
imap_port: u64::from(env_u16_from(
    get("STALWART_DC_IMAP_PORT").as_deref(),
    env_u16_from(get("STALWART_LISTEN_IMAP").as_deref(), 993),
)),
smtp_port: u64::from(env_u16_from(
    get("STALWART_DC_SMTP_PORT").as_deref(),
    env_u16_from(get("STALWART_LISTEN_SUBMISSIONS").as_deref(), 465),
)),
imap_host: env_str_from(get("STALWART_DC_IMAP_HOST").as_deref(), ""),
smtp_host: env_str_from(get("STALWART_DC_SMTP_HOST").as_deref(), ""),
```

Host default in the binary is `""`. Installer may write the hostname into those env keys. Do not move the listener/DeltaChat insert loops above the bootstrap/recovery early returns.

- [ ] **Step 4: Run** `cargo test -p common delta_chat_from_env --lib` — PASS

- [ ] **Step 5: Review ×3, commit**

```bash
git add crates/common/src/manager/defaults.rs
git commit -m "feat(common): seed DeltaChat endpoints from STALWART_DC_* env"
```

---

### Task 5: `install.sh` helpers (make `scripts/test-install.sh` pass)

**Files:**
- Modify: `install.sh` (add functions **before** `main`; keep `INSTALL_TEST` guard at EOF)
- Test: `scripts/test-install.sh` (already written; do not rewrite unless a helper name is wrong)

**Interfaces:**
- Produces (POSIX sh, no bash arrays):

```sh
validate_source()   # owner/repo OR https:// URL OR readable *.tar.gz
validate_version()  # latest or [A-Za-z0-9._-]+
validate_prefix()   # absolute, not / /bin /sbin /lib /usr /dev /proc /sys
validate_user()     # ^[a-z_][a-z0-9_-]*$ and length <= 32
validate_hostname() # RFC 1123 or IPv4 (spec still allows IPv4)
validate_public_url()
validate_admin()    # random OR user:pass, pass >= 12, user ^[A-Za-z0-9_-]+$, reject CR/LF/'
validate_mode()     # 1|2|3
validate_yes_no()
validate_port()     # 0-65535
validate_dc_security()  # ssl|starttls|default|plain
validate_dc_ic()        # 0|1|3
artifact_target()   # OS arch → slug; Darwin fails
download_url()      # repo/url, tag, target → tarball URL; component always stalwart
resolve_paths()     # prefix os → eval-able assignments
upsert_env()        # file key value — uncomment or append; leave other keys
quote_env_value()   # reject CR/LF/' ; always wrap in single quotes
```

`validate_source`: reject `http://` (https only). Existing test uses `https://example.com/releases` — keep that passing. If a test for `http://` is added, it must fail.

Return 0 on ok, 1 on fail. No `exit` inside validators.

- [ ] **Step 1: Run existing tests to see they fail**

Run: `sh scripts/test-install.sh`
Expected: FAIL `validate_source: not found` (or similar)

- [ ] **Step 2: Implement the helpers** at the top of `install.sh` after `set -u`, before `main`. Match the assertions already in `scripts/test-install.sh` exactly (`artifact_target Linux x86_64` → `x86_64-linux`, FreeBSD `amd64` → `x86_64-freebsd`, Darwin fails).

`upsert_env file key value`:
- Reject value containing CR, LF, or `'`. Fail the validator, do not write.
- Always write `KEY='value'` via `printf '%s=%s\n' "$key" "'$value'"` (no unquoted heredoc for secrets).
- If a line `^#?KEY=` exists, replace that line; else append. Do not touch other keys.

`download_url repo tag target`:
- `owner/repo` + `latest` → `https://github.com/${repo}/releases/latest/download/stalwart-${target}.tar.gz`
- `owner/repo` + tag → `https://github.com/${repo}/releases/download/${tag}/stalwart-${target}.tar.gz`
- URL prefix → `${url%/}/stalwart-${target}.tar.gz`

- [ ] **Step 3: Run** `sh scripts/test-install.sh`
Expected: `ALL PASSED`

- [ ] **Step 4: Add port/DC validators to `scripts/test-install.sh`** (same file, after existing validators):

```sh
expect_ok validate_port 0
expect_ok validate_port 65535
expect_fail validate_port 65536
expect_fail validate_port -1
expect_ok validate_dc_security ssl
expect_fail validate_dc_security bogus
expect_ok validate_dc_ic 3
expect_fail validate_dc_ic 2
```

Run `sh scripts/test-install.sh` again — PASS

- [ ] **Step 5: Review ×3, commit**

```bash
git add install.sh scripts/test-install.sh
git commit -m "feat(install): validators, paths, upsert_env for interactive installer"
```

---

### Task 6: `write_env_file` + unattended flags

**Files:**
- Modify: `install.sh` `write_env_file`, `print_usage`, `main` argv loop
- Test: `scripts/test-install.sh`

**Interfaces:**
- `write_env_file "$path"` writes all keys (commented template + assigned values for this run). Always write the listen/TLS/DC set with the resolved values (spec: full set).
- Flags from spec §3. Unknown flag still errors.
- `--admin` invalid → exit non-zero, same one-line errors, no fallback to random.
- Drop `--fdb`. Drop Darwin branch in `main`.
- Positional PREFIX remains accepted **or** `--prefix` (if both, last `--prefix` wins; extra positional errors). Prefer `--prefix` only plus keep one positional for compat with current `install.sh PREFIX`.

Env keys written (uncommented when set this run):

```
STALWART_HOSTNAME
STALWART_PUBLIC_URL
STALWART_LISTEN_SMTP=25
STALWART_LISTEN_SUBMISSION=587
STALWART_LISTEN_SUBMISSIONS=465
STALWART_LISTEN_IMAP=993
STALWART_LISTEN_POP3=995
STALWART_LISTEN_SIEVE=4190
STALWART_LISTEN_HTTPS=443
STALWART_LISTEN_HTTP=8080
STALWART_TLS=true
STALWART_DC_IMAP_HOST
STALWART_DC_IMAP_PORT
STALWART_DC_IMAP_SECURITY=ssl
STALWART_DC_SMTP_HOST
STALWART_DC_SMTP_PORT
STALWART_DC_SMTP_SECURITY=ssl
STALWART_DC_IC=3
# STALWART_RECOVERY_ADMIN only if custom
```

Do not write `STALWART_RECOVERY_MODE=true`.

- [ ] **Step 1: Test write_env_file in `scripts/test-install.sh`**

`write_env_file` reads these globals (set in `main`, overridable in tests): `_hostname` `_public_url` `_listen_smtp` `_listen_submission` `_listen_submissions` `_listen_imap` `_listen_pop3` `_listen_sieve` `_listen_https` `_listen_http` `_tls` `_dc_imap_host` `_dc_imap_port` `_dc_imap_security` `_dc_smtp_host` `_dc_smtp_port` `_dc_smtp_security` `_dc_ic` `_admin` (empty means omit `STALWART_RECOVERY_ADMIN`).

```sh
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
grep -q '^STALWART_LISTEN_SUBMISSION=587$' "$_tmp" || fail env-587
grep -q '^STALWART_TLS=true$' "$_tmp" || fail env-tls
grep -q '^STALWART_DC_IC=3$' "$_tmp" || fail env-ic
if grep -q '^STALWART_RECOVERY_MODE=' "$_tmp"; then fail no-recovery-mode; fi
if grep -q '^STALWART_RECOVERY_ADMIN=' "$_tmp"; then fail no-admin-when-random; fi
rm -f "$_tmp"
ok write_env_file
```

- [ ] **Step 2: Run tests — fail because template lacks listen keys**

- [ ] **Step 3: Implement `write_env_file` and argv parse** (one `while` case per flag). `--http-port` sets `_listen_http`. `--https-port` sets `_listen_https` not `STALWART_HTTPS_PORT`. `--repo`/`--file` run `validate_source` (https only).

Every assignment is `KEY='value'` via `printf`. Reject CR/LF/`'` in admin, hostname, DC hosts. Never write `STALWART_HTTPS_PORT` or `STALWART_RECOVERY_MODE`.

- [ ] **Step 4: Run** `sh scripts/test-install.sh` — PASS

- [ ] **Step 5: Review ×3, commit**

```bash
git add install.sh scripts/test-install.sh
git commit -m "feat(install): write STALWART_LISTEN_* / TLS / DC env and flags"
```

---

### Task 7: TTY, mode, prompts

**Files:**
- Modify: `install.sh` `main`
- Test: `scripts/test-install.sh`

**Interfaces:**
- `is_tty`: `[ -t 0 ]`
- No TTY and no `_yes` and no `_update`: `err "Non-interactive stdin requires -y or --update."`
- `_yes` and binary exists at resolved bin path: force mode 1
- `_yes` and no binary: fresh defaults
- Interactive existing binary: prompt 1/2/3
- Mode 1: skip path/user/hostname/ports/admin; download + atomic replace + restart unless `--no-start`
- Mode 2: `upsert_env` hostname, public URL, admin only. Do **not** prompt or write `STALWART_LISTEN_*` / `STALWART_TLS` / `STALWART_DC_*` (inert after first insert). Do not rewrite whole file. Do not wipe data/`config.json`.
- Mode 3: replace binary + recreate `stalwart.env`; do **not** wipe data/`config.json`. Drop leftover `STALWART_HTTPS_PORT` from the new env file.
- Prompts: one `prompt_port varname default` loop over the eight listen keys (fresh install only); DC host/port share the same prompt helper; security/ic use the two validators. Do not copy eight prompt blocks. `read` with default on empty; loop on `validate_*` fail with the spec one-liners.
- Extract: `tar -t` first; allow only `stalwart` or `./stalwart`; refuse `..`, absolute paths, and symlinks; then extract that one member with `--no-same-owner`. Copy the file, not a symlink.
- `--repo` / `--file` must pass `validate_source`. Keep curl/wget `--proto '=https'` / `--https-only`.
- Bootstrap URL: `http://${_hostname}:${_recovery_port}/admin` where `_recovery_port` is `STALWART_RECOVERY_MODE_PORT` else non-zero `STALWART_LISTEN_HTTP` else 8080. Never print `:0`.
- Never write `STALWART_HTTPS_PORT`. If listen HTTPS ≠ 443, default public URL is `https://${_hostname}:${_listen_https}`.

- [ ] **Step 1: Tests that do not need root**

```sh
sh install.sh --help | grep -q -- '--imap-port' || fail help-imap

# no TTY, no -y
if sh install.sh --prefix /tmp/nope 2>/dev/null; then
    fail 'piped install without -y should exit'
fi
ok tty-guard
```

Do **not** add `printf '\n' | sh install.sh` as a success test. Do not add a second `parse_args` test surface.

- [ ] **Step 2: Run — fail (help/flags/tty missing)**

- [ ] **Step 3: Implement prompt loop + tty + modes in `main`.** Keep download/service functions; delete Darwin `create_service_macos` and `--fdb`.

Prompt order matches spec steps 3–10.

- [ ] **Step 4: Run** `sh scripts/test-install.sh` and `sh install.sh --help` — PASS / prints flags

- [ ] **Step 5: Review ×3, commit**

```bash
git add install.sh scripts/test-install.sh
git commit -m "feat(install): interactive prompts, tty guard, update modes"
```

---

## Spec coverage

| Spec | Task |
|---|---|
| §1.1 env_u16 / defaults | 1 |
| Listen table + 587 + TLS + skip 0 | 2 |
| Recovery HTTP fallback | 3 |
| DeltaChat STALWART_DC_* first insert | 4 |
| First insert only / no config.json from installer | 2, 4, 6 |
| Validators + paths + upsert | 5 |
| Flags + write env | 6 |
| Prompts, TTY C+B, modes, https-only, extract | 7 |
| Admin random / ≥12 | 5–7 |
| Drop macOS / --fdb | 6–7 |

Not in this plan (not in spec as implement-now): SHA-256 of tarball, world-writable prefix reject, FQDN-only hostname. Add only if a later spec edit says so.

## Execution

Plan saved to `docs/superpowers/plans/2026-10-17-interactive-installer-implementation.md`.

Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, three-agent review between tasks
2. **Inline Execution** — this session, executing-plans, checkpoints

Which approach?
