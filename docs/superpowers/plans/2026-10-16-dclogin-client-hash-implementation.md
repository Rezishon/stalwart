# Configurable DCLogin + Client Hash Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Admin-configured DCLogin endpoints/`ic`, unified `Authentication.passwordHashAlgorithm` for every new secret, SPA builds the QR and POSTs only a PHC hash.

**Architecture:** Store IMAP/SMTP/`ic` on the existing `x:DeltaChat` singleton. Copy `server.core.network.security.password_hash_algorithm` into `GET /api/v1/config`. Account handlers accept `password_hash`, reject plaintext, store the hash as-is. SPA is the only `dclogin:` builder. No username/password generator and no URI builder on the backend.

**Tech Stack:** Rust (`crates/deltachat`, `crates/registry`, `crates/http`), Stalwart WebUI schema (`resources/schema/schema.json.gz`), React + TypeScript SPA (`signup-relay/frontend`), `hash-wasm`, `node --test` on `*.test.ts`.

**Spec:** `docs/superpowers/specs/2026-10-16-dclogin-client-hash-design.md`

## Global Constraints

- No hardcoded `ic=3`, `993`, `465`, `ssl`, `localhost`, `mail.{domain}`, or `PasswordHashAlgorithm::Argon2id` for new secrets.
- Do not edit Django `signup-relay/backend` or static sites `dc.tabarestangnu.ir` / `delta.sudoshz.ir`.
- Skip `iu` `ipw` `su` `spw` `sc`.
- Clean code, DRY, KISS. Edit registry schema files by hand (they are marked auto-generated; this repo already does that for DeltaChat).
- English for comments and docs.
- `crates/registry/src/schema/{properties,structs,enums}*.rs` — append new `Property` ids 949–955; bump `Property::COUNT` from 949 to 956.
- Work from `stalwart/` for Rust; SPA lives at `../signup-relay/frontend` relative to that crate.
- Frontend language is TypeScript. New tests are `*.test.ts`, never new `.js`. Convert a `.test.js` when that file is in the task.
- Core outside `crates/deltachat` is only: registry pickle/properties, `schema.json.gz`, OAuth `registration.rs`. Do not touch IMAP/SMTP listeners or `directory::hash_secret`.
- Delete `generate_instant_credentials` and `dclogin.rs`. Do not add a replacement URI builder in Rust.

## Done gate (every task)

After tests pass, before commit, run **two agents** (or `/agents-flow` security-reviewer + a clean-code pass). Task is not done if either fails.

1. **Security** — no plaintext password in logs/responses/POST accept path; no hardcoded `ic`/hosts/hash; prefix check cannot be skipped; no new public JMAP.
2. **Language + KISS/DRY** — Rust idioms in Rust tasks, TypeScript idioms in SPA tasks; no extra files, no silent fallbacks.

## Roadmap

```
1. EndpointSecurity + CertificateChecks types   (no URI builder)
2. Hash prefix check
3. Registry DeltaChat endpoints + ic            pickle v3  [core seam]
4. WebUI Endpoints form                         schema.json.gz  [core seam]
5. Settings + GET /api/v1/config
6. Account POST hash-only; delete generators + dclogin.rs
7. OAuth client secret uses unified algo        [core seam]
8. SPA TypeScript: URI + hash
9. SPA onboarding
10. Crate e2e
```

Each phase is independently testable. Stop after a phase if review fails.

## File map

| File | Role |
|---|---|
| `crates/deltachat/src/config.rs` | `EndpointSecurity` (+ default/plain), `CertificateChecks`, endpoints on `DeltaChatSettings` |
| `crates/deltachat/src/dclogin.rs` | **Delete** once handlers stop calling it |
| `crates/deltachat/src/password_hash.rs` | **Create.** Prefix check vs `PasswordHashAlgorithm` |
| `crates/deltachat/src/handlers/{system,accounts}.rs` | Config JSON; store hash; no URI in response |
| `crates/deltachat/src/models.rs` | Config + account DTOs |
| `crates/deltachat/src/error.rs` | `InvalidPasswordHash`, `EndpointsNotConfigured` |
| `crates/registry/src/schema/structs.rs` + `structs_impl.rs` | Seven new fields, pickle v3 |
| `crates/registry/src/schema/properties.rs` + `properties_impl.rs` | Property 949–955 |
| `resources/schema/schema.json.gz` | Endpoints view + fields |
| `crates/http/src/auth/oauth/registration.rs` | Use server hash algorithm |
| `../signup-relay/frontend/src/utils/dclogin.ts` | Required options, no defaults |
| `../signup-relay/frontend/src/utils/password-hash.ts` | **Create.** WASM PHC hash |
| `../signup-relay/frontend/src/services/*` | Config + POST `password_hash` |
| `../signup-relay/frontend/src/components/onboarding/*` | Build URI locally |

---

### Task 1: Endpoint security and `ic` types (no URI builder)

**Files:**
- Modify: `crates/deltachat/src/config.rs`

**Interfaces:**
- Produces: `CertificateChecks`, `EndpointSecurity::{Ssl,Starttls,Default,Plain}` with `as_str()`
- Does **not** produce `build_dclogin_uri`. Leave `dclogin.rs` as-is until Task 6 deletes it.

- [ ] **Step 1: Write the failing test** in `config.rs` tests:

```rust
#[test]
fn security_and_ic_round_trip_as_dclogin_tokens() {
    assert_eq!(EndpointSecurity::Starttls.as_str(), "starttls");
    assert_eq!(EndpointSecurity::Plain.as_str(), "plain");
    assert_eq!(EndpointSecurity::Default.as_str(), "default");
    assert_eq!(CertificateChecks::Strict.as_str(), "1");
    assert_eq!(CertificateChecks::Automatic.as_str(), "0");
    assert_eq!(CertificateChecks::AcceptInvalid.as_str(), "3");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p deltachat security_and_ic_round_trip --offline`
Expected: FAIL (`CertificateChecks` / `Plain` missing)

- [ ] **Step 3: Minimal implementation** in `config.rs`:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum EndpointSecurity {
    #[default]
    Ssl,
    Starttls,
    Default,
    Plain,
}

impl EndpointSecurity {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Ssl => "ssl",
            Self::Starttls => "starttls",
            Self::Default => "default",
            Self::Plain => "plain",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum CertificateChecks {
    Automatic = 0,
    Strict = 1,
    #[default]
    AcceptInvalid = 3,
}

impl CertificateChecks {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Automatic => "0",
            Self::Strict => "1",
            Self::AcceptInvalid => "3",
        }
    }
}
```

Do not edit `dclogin.rs` in this task.

- [ ] **Step 4: Run tests**

Run: `cargo test -p deltachat --lib --offline`
Expected: PASS for the new test. Existing `dclogin.rs` tests may still assert `ic=3`; leave them until Task 6.

- [ ] **Step 5: Two-agent review** then commit

Security: types only, no secrets. Clean code: no URI builder added.

```bash
git add crates/deltachat/src/config.rs
git commit -m "$(cat <<'EOF'
feat(deltachat): advertise ssl/starttls/default/plain and ic tokens

Types for /api/v1/config. QR building stays in the SPA.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Accept only PHC hashes for the configured algorithm

**Files:**
- Create: `crates/deltachat/src/password_hash.rs`
- Modify: `crates/deltachat/src/lib.rs` (`pub mod password_hash;`)
- Modify: `crates/deltachat/src/error.rs`

**Interfaces:**
- Consumes: `registry::schema::enums::PasswordHashAlgorithm`
- Produces: `password_hash_matches(algorithm, hash: &str) -> bool`, `DeltaChatError::InvalidPasswordHash`

- [ ] **Step 1: Write the failing test** in `password_hash.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use registry::schema::enums::PasswordHashAlgorithm;

    #[test]
    fn accepts_matching_prefix() {
        assert!(password_hash_matches(
            PasswordHashAlgorithm::Argon2id,
            "$argon2id$v=19$m=16,t=2,p=1$c2FsdHNhbHQ$dummy"
        ));
        assert!(password_hash_matches(
            PasswordHashAlgorithm::Bcrypt,
            "$2b$10$abcdefghijklmnopqrstuu12345678901234567890123"
        ));
        assert!(password_hash_matches(
            PasswordHashAlgorithm::Scrypt,
            "$scrypt$ln=15,r=8,p=1$c2FsdA$hash"
        ));
        assert!(password_hash_matches(
            PasswordHashAlgorithm::Pbkdf2,
            "$pbkdf2-sha256$29000$c2FsdA$hash"
        ));
    }

    #[test]
    fn rejects_wrong_algorithm_and_garbage() {
        assert!(!password_hash_matches(
            PasswordHashAlgorithm::Argon2id,
            "$2b$10$notargon"
        ));
        assert!(!password_hash_matches(
            PasswordHashAlgorithm::Argon2id,
            "plaintext"
        ));
        assert!(!password_hash_matches(
            PasswordHashAlgorithm::Argon2id,
            ""
        ));
        assert!(!password_hash_matches(
            PasswordHashAlgorithm::Argon2id,
            "$argon2i$v=19$m=16,t=2,p=1$xx$yy"
        ));
    }
}
```

- [ ] **Step 2: Run to fail**

Run: `cargo test -p deltachat password_hash --offline`
Expected: FAIL compile (`password_hash` module missing)

- [ ] **Step 3: Implement**

```rust
use registry::schema::enums::PasswordHashAlgorithm;

pub fn password_hash_matches(algorithm: PasswordHashAlgorithm, hash: &str) -> bool {
    let prefix = match algorithm {
        PasswordHashAlgorithm::Argon2id => "$argon2id$",
        PasswordHashAlgorithm::Bcrypt => "$2",
        PasswordHashAlgorithm::Scrypt => "$scrypt$",
        PasswordHashAlgorithm::Pbkdf2 => "$pbkdf2",
    };
    hash.starts_with(prefix)
}
```

Add to `error.rs`:

```rust
InvalidPasswordHash,
EndpointsNotConfigured,
```

`status`: both `BAD_REQUEST`. `error_code`: `invalid_password_hash`, `endpoints_not_configured`. Display strings: `"Password hash does not match the configured algorithm"`, `"IMAP/SMTP endpoints are not configured"`.

- [ ] **Step 4: Run tests**

Run: `cargo test -p deltachat password_hash --offline`
Expected: PASS

- [ ] **Step 5: Two-agent review** then commit

Security: prefix check has no bypass, no logging of hashes. Clean code: one function, no extra trait.

```bash
git add crates/deltachat/src/password_hash.rs crates/deltachat/src/lib.rs crates/deltachat/src/error.rs
git commit -m "$(cat <<'EOF'
feat(deltachat): reject password hashes that do not match server algorithm

Prefix check only; no re-hash and no plaintext on this path.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Persist endpoints and `ic` on `x:DeltaChat` (pickle v3)

**Files:**
- Modify: `crates/registry/src/schema/properties.rs` (append after `AltchaHmacSecret = 948`)
- Modify: `crates/registry/src/schema/properties_impl.rs` (`tiny_map`, `as_str`, `from_id`, `COUNT`)
- Modify: `crates/registry/src/schema/structs.rs` (`struct DeltaChat`)
- Modify: `crates/registry/src/schema/structs_impl.rs` (`ObjectImpl::VERSION = 3`, pickle, default, IntoValue, patch)

**Interfaces:**
- Produces: `DeltaChat.{imap_host,imap_port,imap_security,smtp_host,smtp_port,smtp_security,certificate_checks}`

Property ids (do not reuse):

```
ImapHost = 949
ImapPort = 950
ImapSecurity = 951
SmtpHost = 952
SmtpPort = 953
SmtpSecurity = 954
CertificateChecks = 955
```

`Property` `COUNT: usize = 956`.

JSON names: `imapHost`, `imapPort`, `imapSecurity`, `smtpHost`, `smtpPort`, `smtpSecurity`, `certificateChecks`.

Struct fields (serde rename as above):

```rust
pub imap_host: String,
pub imap_port: u64,
pub imap_security: String,
pub smtp_host: String,
pub smtp_port: u64,
pub smtp_security: String,
pub certificate_checks: String,
```

Defaults: empty hosts, ports `993`/`465`, security `"ssl"`, `certificate_checks: "3"`. Empty host is allowed on the object (admin may save incomplete); signup POST rejects empty hosts.

- [ ] **Step 1: Write failing pickle test** in `structs_impl.rs` `deltachat_pickle_tests`:

```rust
#[test]
fn roundtrip_v3_endpoints() {
    let orig = DeltaChat {
        imap_host: "imap.example.org".into(),
        imap_port: 993,
        imap_security: "ssl".into(),
        smtp_host: "smtp.example.org".into(),
        smtp_port: 465,
        smtp_security: "starttls".into(),
        certificate_checks: "1".into(),
        ..Default::default()
    };
    let bytes = orig.to_pickled_vec();
    let mut stream = PickledStream::new(&bytes).unwrap();
    assert_eq!(orig, DeltaChat::unpickle(&mut stream).unwrap());
}

#[test]
fn unpickle_v2_leaves_endpoint_defaults() {
    let v2 = DeltaChat {
        domain_id: Id::from(7u32),
        ..Default::default()
    };
    // Build a v2 blob by pickling with VERSION temporarily is not possible.
    // Keep existing unpickle_v0 test; add: v2 path ignores missing endpoint bytes.
    let orig = DeltaChat {
        domain_id: Id::from(7u32),
        allowed_domains: Map::new(vec![Id::from(7u32), Id::from(9u32)]),
        ..Default::default()
    };
    // v2 roundtrip still works after VERSION bump only if unpickle reads
    // extra fields when version >= 3. Existing roundtrip_v2 must keep passing
    // by writing VERSION 3 for new objects. Rename it roundtrip_current.
    let bytes = orig.to_pickled_vec();
    let mut stream = PickledStream::new(&bytes).unwrap();
    assert_eq!(orig, DeltaChat::unpickle(&mut stream).unwrap());
}
```

Keep `unpickle_v0_enabled_only_blob`. In `unpickle`, after v2 altcha fields, if `stream.version() >= 3` read the seven new fields; else leave defaults.

- [ ] **Step 2: Run to fail**

Run: `cargo test -p registry roundtrip_v3_endpoints --offline`
Expected: FAIL (fields missing)

- [ ] **Step 3: Implement fields, pickle, patch, IntoValue, Default, tiny_map, as_str, from_id, COUNT**

`imap_security` / `smtp_security` validate in `ObjectImpl::validate` as one of `ssl|starttls|default|plain`. `certificate_checks` one of `0|1|3`. Invalid → `ValidationError::required` on that property.

- [ ] **Step 4: Run tests**

Run: `cargo test -p registry deltachat_pickle --offline`
Expected: PASS

- [ ] **Step 5: Two-agent review** then commit

This is a **core seam** (registry). Security: no secrets in new fields. Clean code: follow existing DeltaChat pickle v2 pattern; do not regenerate the whole schema crate.

```bash
git add crates/registry/src/schema/properties.rs crates/registry/src/schema/properties_impl.rs crates/registry/src/schema/structs.rs crates/registry/src/schema/structs_impl.rs
git commit -m "$(cat <<'EOF'
feat(registry): persist DeltaChat IMAP/SMTP endpoints and certificate checks

Pickle v3; v0/v2 blobs still unpickle with empty hosts.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Admin Endpoints form

**Files:**
- Modify: `resources/schema/schema.json.gz` and `schema.json.sha256`

Decompress, edit, recompress. Do not commit an uncompressed `schema.json` unless the repo already tracks it (it does not).

- [ ] **Step 1: Decompress**

```bash
gzip -dkc resources/schema/schema.json.gz > /tmp/schema.json
```

- [ ] **Step 2: Add object view, fields, form, layout link**

`objects["x:DeltaChat/DeltaChatEndpoints"]`: `{ "type": "view", "objectName": "x:DeltaChat" }`

`fields["x:DeltaChat"].properties` add:

```json
"imapHost": { "description": "IMAP hostname advertised in dclogin URIs", "type": { "type": "string", "format": "string" }, "update": "mutable" },
"imapPort": { "description": "IMAP port", "type": { "type": "number", "format": "unsignedInteger" }, "update": "mutable" },
"imapSecurity": { "description": "IMAP socket security", "type": { "type": "string", "enum": ["ssl", "starttls", "default", "plain"] }, "update": "mutable" },
"smtpHost": { "description": "SMTP hostname advertised in dclogin URIs", "type": { "type": "string", "format": "string" }, "update": "mutable" },
"smtpPort": { "description": "SMTP port", "type": { "type": "number", "format": "unsignedInteger" }, "update": "mutable" },
"smtpSecurity": { "description": "SMTP socket security", "type": { "type": "string", "enum": ["ssl", "starttls", "default", "plain"] }, "update": "mutable" },
"certificateChecks": { "description": "Delta Chat ic (0 automatic, 1 strict, 3 accept-invalid)", "type": { "type": "string", "enum": ["0", "1", "3"] }, "update": "mutable" }
```

`fields["x:DeltaChat"].defaults` add `"imapPort": 993, "smtpPort": 465, "imapSecurity": "ssl", "smtpSecurity": "ssl", "certificateChecks": "3"`.

`forms["x:DeltaChat/DeltaChatEndpoints"]`:

```json
{
  "title": "DeltaChat Endpoints",
  "subtitle": "IMAP and SMTP values written into dclogin QR codes",
  "sections": [
    {
      "title": "IMAP",
      "fields": [
        { "name": "imapHost", "label": "IMAP Host" },
        { "name": "imapPort", "label": "IMAP Port" },
        { "name": "imapSecurity", "label": "IMAP Security" }
      ]
    },
    {
      "title": "SMTP",
      "fields": [
        { "name": "smtpHost", "label": "SMTP Host" },
        { "name": "smtpPort", "label": "SMTP Port" },
        { "name": "smtpSecurity", "label": "SMTP Security" }
      ]
    },
    {
      "title": "Certificates",
      "fields": [
        { "name": "certificateChecks", "label": "Certificate Checks (ic)" }
      ]
    }
  ]
}
```

In `layouts`, find the DeltaChat container `items` array (General, Domains, Altcha) and insert after Domains:

```json
{ "name": "Endpoints", "type": "link", "viewName": "x:DeltaChat/DeltaChatEndpoints" }
```

- [ ] **Step 3: Recompress**

```bash
gzip -k9 -c /tmp/schema.json > resources/schema/schema.json.gz
sha256sum resources/schema/schema.json.gz | awk '{print $1}' > resources/schema/schema.json.sha256
```

- [ ] **Step 4: Sanity**

```bash
python3 -c "import gzip,json; d=json.loads(gzip.open('resources/schema/schema.json.gz').read()); assert 'x:DeltaChat/DeltaChatEndpoints' in d['forms']; print('ok')"
```

Expected: `ok`

- [ ] **Step 5: Two-agent review** then commit

This is a **core seam** (WebUI schema). Security: form is admin-only (`sysSystemSettings`); no public leak of hmac. Clean code: one new view, reuse `x:DeltaChat` object.

```bash
git add resources/schema/schema.json.gz resources/schema/schema.json.sha256
git commit -m "$(cat <<'EOF'
feat(webui): DeltaChat Endpoints admin form for dclogin advertisement

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Settings + public config (no inferred hosts)

**Files:**
- Modify: `crates/deltachat/src/config.rs` (`DeltaChatSettings`, `From<registry DeltaChat>`, drop `advertised_mail_endpoint` inference)
- Modify: `crates/deltachat/src/models.rs`
- Modify: `crates/deltachat/src/handlers/system.rs`
- Modify: `crates/deltachat/src/router.rs` (`discovery_context`)

**Interfaces:**
- Produces: `DeltaChatSettings.{imap,smtp,certificate_checks}`, `ConfigDiscoveryResponse.password_hash_algorithm`, `certificate_checks`
- `endpoints_from_settings(&DeltaChatSettings) -> Result<EndpointsConfig, DeltaChatError>`

- [ ] **Step 1: Failing config handler test** in `system.rs` tests:

```rust
#[test]
fn config_includes_hash_algorithm_and_ic() {
    let mut settings = DeltaChatSettings::default();
    settings.imap = MailEndpointConfig {
        host: "imap.example.org".into(),
        port: 993,
        security: EndpointSecurity::Ssl,
    };
    settings.smtp = MailEndpointConfig {
        host: "smtp.example.org".into(),
        port: 465,
        security: EndpointSecurity::Ssl,
    };
    settings.certificate_checks = CertificateChecks::Strict;
    let engine = AltchaEngine::new(b"secret".to_vec(), 1000);
    let resp = handle_config(
        &settings,
        &engine,
        "example.org".into(),
        settings.endpoints(),
        "argon2id",
    )
    .unwrap();
    assert_eq!(resp.password_hash_algorithm, "argon2id");
    assert_eq!(resp.certificate_checks, "1");
    assert_eq!(resp.endpoints.imap.host, "imap.example.org");
}
```

- [ ] **Step 2: Run to fail**

Run: `cargo test -p deltachat config_includes_hash_algorithm --offline`
Expected: FAIL (new fields / arity)

- [ ] **Step 3: Implement**

`DeltaChatSettings` gains `imap: MailEndpointConfig`, `smtp: MailEndpointConfig`, `certificate_checks: CertificateChecks`. `From<registry::DeltaChat>` maps strings via helpers:

```rust
fn parse_security(s: &str) -> EndpointSecurity {
    match s {
        "starttls" => EndpointSecurity::Starttls,
        "default" => EndpointSecurity::Default,
        "plain" => EndpointSecurity::Plain,
        _ => EndpointSecurity::Ssl,
    }
}
fn parse_ic(s: &str) -> CertificateChecks {
    match s {
        "0" => CertificateChecks::Automatic,
        "1" => CertificateChecks::Strict,
        _ => CertificateChecks::AcceptInvalid,
    }
}
```

Delete `advertised_endpoints(server)` and `advertised_mail_endpoint`. `default_endpoints()` stays for tests only.

`handle_config(..., endpoints, password_hash_algorithm: &str)`.

`PasswordHashAlgorithm` public string:

```rust
pub fn password_hash_algorithm_str(a: PasswordHashAlgorithm) -> &'static str {
    match a {
        PasswordHashAlgorithm::Argon2id => "argon2id",
        PasswordHashAlgorithm::Bcrypt => "bcrypt",
        PasswordHashAlgorithm::Scrypt => "scrypt",
        PasswordHashAlgorithm::Pbkdf2 => "pbkdf2",
    }
}
```

Put this next to `password_hash_matches` in `password_hash.rs`.

Router `discovery_context`: domain from `domain_id` as today; endpoints from settings, **not** `server_name`. Pass `server.core.network.security.password_hash_algorithm` into `handle_config`.

`ConfigDiscoveryResponse`:

```rust
pub password_hash_algorithm: String,
pub certificate_checks: String,
```

- [ ] **Step 4: Run**

Run: `cargo test -p deltachat --lib --offline`
Expected: PASS for system/config tests

- [ ] **Step 5: Two-agent review** then commit

Security: public config has no hmac secret, no passwords. Clean code: delete `advertised_endpoints`; do not keep a fallback to `server_name`.

```bash
git add crates/deltachat/src/config.rs crates/deltachat/src/models.rs crates/deltachat/src/handlers/system.rs crates/deltachat/src/router.rs crates/deltachat/src/password_hash.rs
git commit -m "$(cat <<'EOF'
feat(deltachat): advertise endpoints, ic, and hash algorithm from config

Stop inferring IMAP/SMTP hosts from server_name.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Account POST stores client hash

**Files:**
- Modify: `crates/deltachat/src/models.rs`
- Modify: `crates/deltachat/src/handlers/accounts.rs`

**Interfaces:**
- Consumes: `password_hash_matches`, settings endpoints
- Produces: `InstantAccountRequest { username, password_hash, altcha_payload }`, `CustomAccountRequest { username, password_hash, altcha_payload }`, responses without `password` / `dclogin_link`

Instant username must match `^dc_[0-9a-f]{12}$`. Custom still uses `validate_username` (`dc_` forbidden).

If `settings.imap.host` or `settings.smtp.host` is empty → `EndpointsNotConfigured`.

If `password_hash` missing or `!password_hash_matches(server.core.network.security.password_hash_algorithm, hash)` → `InvalidPasswordHash`.

If body contains `password` (serde deny unknown? **do not** deny unknown globally). Explicitly: if a `password` field deserializes, reject. Add `#[serde(default)] password: Option<String>` and if `Some(_)`, `InvalidPassword`.

Store `password_hash` as `PasswordCredential.secret`. Do not call `hash_secret`.

Response:

```rust
pub struct InstantAccountResponse {
    pub account_id: String,
    pub email: String,
    pub account_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<String>,
}
pub struct CustomAccountResponse {
    pub account_id: String,
    pub email: String,
    pub account_type: String,
}
```

**Delete** `generate_instant_credentials` entirely (no `dc_` generator, no password generator). Keep `validate_instant_username` only. Delete `dclogin.rs` and its `mod dclogin` / `use` sites (`lib.rs`, `accounts.rs`, `e2e_tests.rs`). URI tests move to SPA Task 8.

- [ ] **Step 1: Failing tests** in `accounts.rs`:

```rust
#[test]
fn instant_username_must_be_dc_hex12() {
    assert!(validate_instant_username("dc_0123456789ab").is_ok());
    assert!(validate_instant_username("alice").is_err());
    assert!(validate_instant_username("dc_ZZ").is_err());
}

#[test]
fn plaintext_password_field_is_rejected_by_model() {
    let json = r#"{"username":"dc_0123456789ab","password":"secret","password_hash":"$argon2id$x"}"#;
    let req: InstantAccountRequest = serde_json::from_str(json).unwrap();
    assert!(req.password.is_some());
}
```

Handler unit tests that need `Server` stay in e2e (Task 9). Here also:

```rust
#[test]
fn custom_still_rejects_dc_prefix() {
    assert!(validate_username("dc_alice").is_err());
}
```

- [ ] **Step 2: Run to fail**

Run: `cargo test -p deltachat instant_username_must_be --offline`
Expected: FAIL

- [ ] **Step 3: Implement request/response + validate_instant_username + handler changes**

```rust
pub fn validate_instant_username(username: &str) -> Result<(), DeltaChatError> {
    let u = username.trim().to_ascii_lowercase();
    let ok = u.len() == 15
        && u.starts_with("dc_")
        && u.as_bytes()[3..].iter().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'));
    if ok {
        Ok(())
    } else {
        Err(DeltaChatError::InvalidUsername(
            "Instant username must match dc_ + 12 hex chars".into(),
        ))
    }
}
```

In both handlers, after altcha:

```rust
if req.password.is_some() {
    return Err(DeltaChatError::InvalidPassword(
        "Plaintext password is not accepted".into(),
    ));
}
if !password_hash_matches(
    server.core.network.security.password_hash_algorithm,
    &req.password_hash,
) {
    return Err(DeltaChatError::InvalidPasswordHash);
}
if settings.imap.host.is_empty() || settings.smtp.host.is_empty() {
    return Err(DeltaChatError::EndpointsNotConfigured);
}
```

`secret: req.password_hash.clone()`.

Remove `validate_password` if unused. Remove `hash_secret` imports from this file.

- [ ] **Step 4: Run**

Run: `cargo test -p deltachat --lib --offline`
Expected: PASS. `dclogin` module must not exist.

- [ ] **Step 5: Two-agent review** then commit

Security: plaintext `password` rejected; hash not re-hashed; no URI with `p=` in JSON. Clean code: generators and `dclogin.rs` gone.

```bash
git add crates/deltachat/src/models.rs crates/deltachat/src/handlers/accounts.rs crates/deltachat/src/lib.rs crates/deltachat/src/dclogin.rs crates/deltachat/tests/e2e_tests.rs
git commit -m "$(cat <<'EOF'
feat(deltachat): store client PHC hashes; drop URI and credential generators

Signup no longer hashes plaintext or builds QR on the server.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```
`git add -u crates/deltachat/src/dclogin.rs` if deleted.

---

### Task 7: OAuth client secrets use the unified algorithm

**Files:**
- Modify: `crates/http/src/auth/oauth/registration.rs`

**Interfaces:**
- Consumes: `self` as Server / access to `core.network.security.password_hash_algorithm`

- [ ] **Step 1: Grep for remaining hardcodes**

Run: `rg "PasswordHashAlgorithm::Argon2id" crates --glob '!target/**'`
Expected: hits in `registration.rs` and possibly tests. Every **production** hash of a new secret must use the server setting. Test fixtures may keep Argon2id literals.

- [ ] **Step 2: Replace OAuth call**

```rust
let secret_hash = hash_secret(
    self.core.network.security.password_hash_algorithm,
    client_secret.clone().into_bytes(),
)
.await
.caused_by(trc::location!())?;
```

Confirm `self` is `Server` (existing `hash_secret` call site around line 160).

- [ ] **Step 3: Re-grep**

Run: `rg "PasswordHashAlgorithm::Argon2id" crates --glob '!target/**'`
Expected: no remaining production signup/OAuth paths. JMAP account mapping already uses the setting.

- [ ] **Step 4: Compile**

Run: `cargo check -p http --offline`
Expected: success

- [ ] **Step 5: Two-agent review** then commit

This is a **core seam** (http OAuth). Security: still hashes server-side (OAuth is not the SPA). Clean code: one line, reuse existing setting.

```bash
git add crates/http/src/auth/oauth/registration.rs
git commit -m "$(cat <<'EOF'
fix(oauth): hash client secrets with Authentication.passwordHashAlgorithm

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: SPA — URI builder and password hash (TypeScript)

**Files:**
- Modify: `../signup-relay/frontend/src/utils/dclogin.ts`
- Create: `../signup-relay/frontend/src/utils/password-hash.ts`
- Modify then rename: `../signup-relay/frontend/tests/dclogin.test.js` → `dclogin.test.ts`
- Create: `../signup-relay/frontend/tests/password-hash.test.ts`
- Modify: `../signup-relay/frontend/package.json` (`hash-wasm`; `test` script includes `*.test.ts`)

**Interfaces:**
- Produces: `buildDcloginUri(options)` all fields required including `certificateChecks`
- Produces: `hashPassword(algorithm: 'argon2id'|'bcrypt'|'scrypt'|'pbkdf2', password: string): Promise<string>`
- Produces: `generateInstantUsername(): string` → `dc_` + 12 hex

- [ ] **Step 1: Failing JS tests**

Replace `buildDcloginUri uses default hosts` with:

```js
test('buildDcloginUri throws when endpoints or ic omitted', () => {
  assert.throws(
    () => buildDcloginUri({ email: 'a@b.c', password: 'x' }),
    /required/
  );
});

test('buildDcloginUri uses provided ic', () => {
  const uri = buildDcloginUri({
    email: 'user@chatchi.org',
    password: 'p',
    imapHost: 'imap.example.org',
    imapPort: 143,
    imapSecurity: 'starttls',
    smtpHost: 'smtp.example.org',
    smtpPort: 587,
    smtpSecurity: 'plain',
    certificateChecks: '1',
  });
  assert.ok(uri.includes('ic=1'));
  assert.ok(!uri.includes('ic=3'));
});
```

`password-hash.test.ts`:

```ts
import test from 'node:test';
import assert from 'node:assert/strict';
import { hashPassword, isSupportedHashAlgorithm } from '../src/utils/password-hash.ts';

test('isSupportedHashAlgorithm lists the four PHC algos', () => {
  assert.equal(isSupportedHashAlgorithm('argon2id'), true);
  assert.equal(isSupportedHashAlgorithm('bcrypt'), true);
  assert.equal(isSupportedHashAlgorithm('scrypt'), true);
  assert.equal(isSupportedHashAlgorithm('pbkdf2'), true);
  assert.equal(isSupportedHashAlgorithm('md5'), false);
});

test('hashPassword argon2id returns phc prefix', async () => {
  const h = await hashPassword('argon2id', 'correct horse');
  assert.ok(h.startsWith('$argon2id$'));
});
```

- [ ] **Step 2: Run to fail**

Run: `cd ../signup-relay/frontend && npm test`
Expected: FAIL

- [ ] **Step 3: Implement**

`dclogin.ts` — no default hosts/ports/security/ic. Throw `Error('DCLogin endpoints are required')` if any of those missing.

`password-hash.ts` using `hash-wasm`:

```ts
import { argon2id, bcrypt, scrypt, pbkdf2 } from 'hash-wasm';

export type HashAlgorithm = 'argon2id' | 'bcrypt' | 'scrypt' | 'pbkdf2';

export function isSupportedHashAlgorithm(a: string): a is HashAlgorithm {
  return a === 'argon2id' || a === 'bcrypt' || a === 'scrypt' || a === 'pbkdf2';
}

export async function hashPassword(algorithm: HashAlgorithm, password: string): Promise<string> {
  switch (algorithm) {
    case 'argon2id':
      return argon2id({ password, salt: crypto.getRandomValues(new Uint8Array(16)), parallelism: 1, iterations: 2, memorySize: 19456, hashLength: 32, outputType: 'encoded' });
    case 'bcrypt':
      return bcrypt({ password, salt: crypto.getRandomValues(new Uint8Array(16)), costFactor: 10, outputType: 'encoded' });
    case 'scrypt':
      return scrypt({ password, salt: crypto.getRandomValues(new Uint8Array(16)), costFactor: 15, blockSize: 8, parallelism: 1, hashLength: 32, outputType: 'encoded' });
    case 'pbkdf2':
      return pbkdf2({ password, salt: crypto.getRandomValues(new Uint8Array(16)), iterations: 29000, hashLength: 32, hashFunction: 'SHA-256', outputType: 'encoded' });
  }
}
```

If `hash-wasm` APIs differ, match their current docs; output **must** start with the prefixes in Task 2.

`npm install hash-wasm` in `signup-relay/frontend`.

Hex instant username:

```ts
export function generateInstantUsername(): string {
  const bytes = new Uint8Array(6);
  crypto.getRandomValues(bytes);
  return 'dc_' + [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
}
```

- [ ] **Step 4: Run**

Run: `cd ../signup-relay/frontend && npm test`
Expected: PASS

Point `package.json` `"test"` at `tests/*.test.ts` (keep `node --test` if it already loads `.ts` via the existing frontend setup; if not, use the same loader the current `*.test.js` imports of `.ts` use).

- [ ] **Step 5: Two-agent review** then commit in `signup-relay` (sibling git root)

Security: salts from `crypto.getRandomValues`; password never logged. Clean code: no default `ic=3`. TypeScript only.

```bash
git add frontend/src/utils/dclogin.ts frontend/src/utils/password-hash.ts frontend/tests/dclogin.test.ts frontend/tests/password-hash.test.ts frontend/package.json frontend/package-lock.json
git rm frontend/tests/dclogin.test.js
git commit -m "$(cat <<'EOF'
feat(frontend): build dclogin from config only; hash passwords in WASM

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: SPA services and onboarding

**Files:**
- Modify: `../signup-relay/frontend/src/services/types.ts`
- Modify: `../signup-relay/frontend/src/services/mockService.ts`
- Modify: `../signup-relay/frontend/src/services/prodService.ts` (only if types force it)
- Modify: `../signup-relay/frontend/src/components/onboarding/InstantQrCard.tsx`
- Modify: `../signup-relay/frontend/src/components/onboarding/CustomWizard.tsx`
- Rename+modify: `../signup-relay/frontend/tests/service.test.js` → `service.test.ts`
- Rename+modify: `../signup-relay/frontend/tests/onboarding.test.js` → `onboarding.test.ts`

**Interfaces:**
- `ServerConfig` adds `password_hash_algorithm`, `certificate_checks`, required `endpoints`
- `InstantAccountPayload`: `{ username, password_hash, altcha_payload? }`
- `CustomAccountPayload`: `{ username, password_hash, altcha_payload? }`
- Results: `{ account_id?, email, account_type }` — **no** `dclogin_link` / `password`

Onboarding holds `{ email, dclogin_link }` in React state built **before** POST.

If `!isSupportedHashAlgorithm(cfg.password_hash_algorithm)` set error and disable generate.

- [ ] **Step 1: Failing onboarding test**

In `onboarding.test.ts`, assert InstantQrCard:

- imports `buildDcloginUri` and `hashPassword` / `generateInstantUsername`
- does **not** read `dclogin_link` from the service result

```js
assert.match(content, /buildDcloginUri/);
assert.match(content, /password_hash/);
assert.doesNotMatch(content, /data\.dclogin_link|account\.dclogin_link/);
```

Wait: after change, local state may still be named `dclogin_link`. Assert the **service result** is not the source:

```js
assert.match(content, /buildDcloginUri\(/);
assert.doesNotMatch(content, /result\.dclogin_link|data\.dclogin_link/);
```

CustomWizard: same.

`service.test.ts`: mock `getConfig` includes `password_hash_algorithm: 'argon2id'` and `certificate_checks`. `createInstantAccount` return has no `dclogin_link`.

- [ ] **Step 2: Run to fail**

Run: `cd ../signup-relay/frontend && npm test`
Expected: FAIL

- [ ] **Step 3: Implement types, mock, InstantQrCard, CustomWizard**

Instant generate sketch:

```ts
const cfg = await service.getConfig();
if (!isSupportedHashAlgorithm(cfg.password_hash_algorithm)) {
  throw new Error('Unsupported hash algorithm');
}
const username = generateInstantUsername();
const password = generateRandomString(24);
const email = `${username}@${cfg.domain}`;
const password_hash = await hashPassword(cfg.password_hash_algorithm, password);
const dclogin_link = buildDcloginUri({
  email,
  password,
  imapHost: cfg.endpoints.imap.host,
  imapPort: cfg.endpoints.imap.port,
  imapSecurity: cfg.endpoints.imap.security,
  smtpHost: cfg.endpoints.smtp.host,
  smtpPort: cfg.endpoints.smtp.port,
  smtpSecurity: cfg.endpoints.smtp.security,
  certificateChecks: cfg.certificate_checks,
});
const data = await service.createInstantAccount({ username, password_hash, altcha_payload: altchaPayload });
setAccount({ email: data.email, dclogin_link, account_type: 'instant' });
```

Custom: keep user-chosen username; generate password in memory; same hash + URI + POST.

Mock `createInstantAccount` / `createCustomAccount` return `{ account_id, email, account_type }` only.

- [ ] **Step 4: Run**

Run: `cd ../signup-relay/frontend && npm test && npm run typecheck`
Expected: PASS

- [ ] **Step 5: Two-agent review** then commit in signup-relay

Security: plaintext stays in RAM; POST body has only `password_hash`. Clean code: one config fetch, no mock `mail.` host invention beyond mock config fields.

```bash
git add frontend/src/services frontend/src/components/onboarding frontend/tests
git rm frontend/tests/service.test.js frontend/tests/onboarding.test.js
git commit -m "$(cat <<'EOF'
feat(frontend): signup hashes locally and builds QR from /api/v1/config

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Crate e2e tests

**Files:**
- Modify: `crates/deltachat/tests/e2e_tests.rs`

- [ ] **Step 1: Update e2e**

- Require `password_hash_algorithm` and `certificate_checks` on `/api/v1/config`.
- **Delete** `test_e2e_dclogin_builder_compliance` (URI builder is gone).
- Instant/custom HTTP tests POST `username` + `password_hash`; assert response has no `dclogin_link` / `password`.
- Remove `use dclogin::build_dclogin_uri`.

- [ ] **Step 2: Run**

Run: `cargo test -p deltachat --offline`
Expected: PASS

- [ ] **Step 3: Two-agent review** then commit

```bash
git add crates/deltachat/tests/e2e_tests.rs
git commit -m "$(cat <<'EOF'
test(deltachat): e2e config and signup match hash-only contract

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

## Self-review

- Spec §3 keys → Tasks 1, 3, 4, 8
- Spec §4 unified hash → Tasks 2, 5, 6, 7
- Spec §5 core seams only (registry, schema.gz, OAuth) → Tasks 3, 4, 7
- Spec §6 public config → Task 5
- Spec §7 POST + no `dc_` generator → Task 6
- Spec §8 SPA TypeScript → Tasks 8–9
- Spec §9 delete `dclogin.rs` / `generate_instant_credentials` → Task 6
- Spec §10.1 two-agent review → every task Step 5
- OAuth leftover Argon2id → Task 7
- No Django, no `sc`/`iu`/`ipw`
- Pickle v3 / Property 949–955 / COUNT 956 named once
- No Rust URI builder after Task 6

## Handoff

Spec: `stalwart/docs/superpowers/specs/2026-10-16-dclogin-client-hash-design.md`
Plan: `stalwart/docs/superpowers/plans/2026-10-16-dclogin-client-hash-implementation.md`
Session memory: `/home/rezishon/.claude/projects/-home-rezishon-Projects-online-projects-riselabs-projects/memory/MEMORY.md`

After `/clear`: subagent-driven, one task at a time, two-agent review before each commit.
