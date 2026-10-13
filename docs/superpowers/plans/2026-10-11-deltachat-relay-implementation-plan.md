# Unified DeltaChat & Relay Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a self-contained, clean, pluggable, and disablable `DeltaChat` module (`crates/deltachat`) in Stalwart with complete feature parity for the Relay backend (public discovery, Altcha PoW, username check, instant/custom onboarding, token-based product auth, mailbox lifecycle CRUD, and WebXDC store).

**Architecture:** A dedicated workspace crate `crates/deltachat` containing configuration, domain models, cryptographic Altcha PoW engine with bounded `CacheWithTtl` replay protection, DeltaChat `dclogin` builder via `form_urlencoded`, product user token authentication, ownership-aware mailbox provisioning service, and WebXDC app catalog. Instantiated as a persistent `Arc<DeltaChatRouter>` on `Server` and dispatched directly from Stalwart's HTTP layer with an active enable/disable runtime toggle.

**Tech Stack:** Rust (Edition 2024), Tokio, Hyper, Serde/Serde-Json, Sha2, Hmac, `form_urlencoded`, `utils::cache::CacheWithTtl`, Stalwart Core Directory, Store & Registry.

**Spec:** `docs/superpowers/specs/2026-10-11-deltachat-relay-module-spec.md`

## Global Constraints

- **Code Quality:** Strict adherence to Clean Code, DRY (Don't Repeat Yourself), and KISS (Keep It Simple, Stupid). No unnecessary abstraction layers.
- **Pluggability:** Module can be compiled in/out via feature flag and enabled/disabled at runtime via `DeltaChatSettings.enabled`.
- **Zero Overhead:** Single-binary operation, in-memory execution, zero external runtime dependencies.
- **Security:** HMAC challenge binding for Altcha PoW, constant-time verification, 120s TTL replay cache, CSPRNG for passwords, async Argon2id hashing, redacted debug logs, and IP rate limiting (anonymous requests only).
- **No Legacy Deadweight:** `/api/v1/blog` is omitted.

---

## Roadmap Overview

```
[Task 1: Crate Skeleton] -> [Task 2: Config & Toggle] -> [Task 3: Error Model]
           |
           v
[Task 4: Public Discovery] -> [Task 5: Altcha PoW Engine] -> [Task 6: dclogin Builder]
           |
           v
[Task 7: Public Account Provisioning] -> [Task 8: Product Identity & Token Auth]
           |
           v
[Task 9: Mailbox Lifecycle CRUD] -> [Task 10: WebXDC Store & Streaming]
           |
           v
[Task 11: Unified HTTP Router] -> [Task 12: Server Singleton & HTTP Wiring] -> [Task 13: E2E Tests]
```

---

### Task 1: Crate Skeleton & Workspace Integration

**Files:**
- Create: `crates/deltachat/Cargo.toml`
- Create: `crates/deltachat/src/lib.rs`
- Modify: `Cargo.toml:workspace.members`

**Interfaces:**
- Produces: `deltachat` crate in workspace.

- [ ] **Step 1: Create `crates/deltachat/Cargo.toml`**

```toml
[package]
name = "deltachat"
version = "0.16.25"
edition = "2024"

[dependencies]
common = { path = "../common" }
types = { path = "../types" }
utils = { path = "../utils" }
store = { path = "../store" }
registry = { path = "../registry" }
directory = { path = "../directory" }
trc = { path = "../trc" }

hyper = { version = "1.11.1", features = ["server", "http1", "http2"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
sha2 = "0.10"
hmac = "0.12"
hex = "0.4"
form_urlencoded = "1.2"
parking_lot = "0.12"
tokio = { version = "1.44", features = ["sync", "time"] }

[dev-dependencies]
tokio = { version = "1.44", features = ["full"] }

[lints]
workspace = true
```

- [ ] **Step 2: Create initial `crates/deltachat/src/lib.rs`**

```rust
//! Unified DeltaChat & Relay Core Module for Stalwart Mail Server.

pub mod config;
pub mod error;
pub mod models;

pub use config::DeltaChatSettings;
pub use error::DeltaChatError;

#[cfg(test)]
mod tests {
    #[test]
    fn test_deltachat_module_loads() {
        assert!(true);
    }
}
```

- [ ] **Step 3: Register `crates/deltachat` in root `Cargo.toml`**

Add `"crates/deltachat"` to `[workspace.members]`.

- [ ] **Step 4: Verify compilation**

Run: `cargo check -p deltachat`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml crates/deltachat/Cargo.toml crates/deltachat/src/lib.rs
git commit -m "feat(deltachat): initialize unified deltachat crate in workspace"
```

---

### Task 2: Configuration & Runtime Enable/Disable Toggle

**Files:**
- Create: `crates/deltachat/src/config.rs`
- Test: `crates/deltachat/src/config.rs:tests`

**Interfaces:**
- Produces: `DeltaChatSettings`, `EndpointsConfig`, `MailEndpointConfig`, `AltchaSettings`

- [ ] **Step 1: Write unit tests for configuration**

In `crates/deltachat/src/config.rs`:
```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config_is_enabled() {
        let config = DeltaChatSettings::default();
        assert!(config.enabled);
        assert!(config.registration_open);
        assert_eq!(config.domain, "localhost");
        assert_eq!(config.endpoints.imap.port, 993);
        assert_eq!(config.endpoints.smtp.port, 465);
    }

    #[test]
    fn test_disabled_config_toggle() {
        let mut config = DeltaChatSettings::default();
        config.enabled = false;
        assert!(!config.enabled);
    }

    #[test]
    fn test_resolved_hmac_key() {
        let altcha = AltchaSettings {
            required: true,
            max_number: 500_000,
            hmac_key: "".to_string(),
        };
        assert_eq!(altcha.resolved_hmac_key().len(), 32);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p deltachat config::tests`  
Expected: FAIL

- [ ] **Step 3: Implement `crates/deltachat/src/config.rs`**

```rust
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MailEndpointConfig {
    pub host: String,
    pub port: u16,
    pub security: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EndpointsConfig {
    pub imap: MailEndpointConfig,
    pub smtp: MailEndpointConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AltchaSettings {
    pub required: bool,
    pub max_number: u64,
    #[serde(skip_serializing)]
    pub hmac_key: String,
}

impl AltchaSettings {
    pub fn resolved_hmac_key(&self) -> Vec<u8> {
        if self.hmac_key.is_empty() || self.hmac_key == "default-chatchi-altcha-secret-key-change-me" {
            store::rand::random::<[u8; 32]>().to_vec()
        } else {
            self.hmac_key.as_bytes().to_vec()
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeltaChatSettings {
    pub enabled: bool,
    pub brand: String,
    pub domain: String,
    pub allowed_domains: Vec<String>,
    pub registration_open: bool,
    pub instant_accounts_enabled: bool,
    pub custom_accounts_enabled: bool,
    pub endpoints: EndpointsConfig,
    pub altcha: AltchaSettings,
    pub default_quota_mb: u64,
}

impl Default for DeltaChatSettings {
    fn default() -> Self {
        Self {
            enabled: true,
            brand: "R.I.S.E / DeltaChat".to_string(),
            domain: "localhost".to_string(),
            allowed_domains: vec!["localhost".to_string()],
            registration_open: true,
            instant_accounts_enabled: true,
            custom_accounts_enabled: true,
            endpoints: EndpointsConfig {
                imap: MailEndpointConfig {
                    host: "localhost".to_string(),
                    port: 993,
                    security: "ssl".to_string(),
                },
                smtp: MailEndpointConfig {
                    host: "localhost".to_string(),
                    port: 465,
                    security: "ssl".to_string(),
                },
            },
            altcha: AltchaSettings {
                required: false,
                max_number: 500_000,
                hmac_key: "".to_string(),
            },
            default_quota_mb: 50,
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test -p deltachat config::tests`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add crates/deltachat/src/config.rs
git commit -m "feat(deltachat): implement DeltaChatSettings with enable/disable toggle"
```

---

### Task 3: Error Model & Safe HTTP JSON Mapping

**Files:**
- Create: `crates/deltachat/src/error.rs`
- Test: `crates/deltachat/src/error.rs:tests`

**Interfaces:**
- Produces: `DeltaChatError` enum and its conversion into status code and safe JSON error payload.

- [ ] **Step 1: Write failing unit test for error status and body**

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_error_status_and_body() {
        let err = DeltaChatError::UsernameTaken("alice".to_string());
        assert_eq!(err.status_code(), 409);
        assert!(err.to_json().contains("username_taken"));

        let disabled_err = DeltaChatError::ModuleDisabled;
        assert_eq!(disabled_err.status_code(), 404);

        let unauth_err = DeltaChatError::Unauthorized;
        assert_eq!(unauth_err.status_code(), 401);

        let internal_err = DeltaChatError::Internal("sensitive sql error".to_string());
        assert_eq!(internal_err.status_code(), 500);
        assert!(!internal_err.to_json().contains("sensitive"));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p deltachat error::tests`  
Expected: FAIL

- [ ] **Step 3: Implement `crates/deltachat/src/error.rs`**

```rust
use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeltaChatError {
    ModuleDisabled,
    Unauthorized,
    NotFound(&'static str),
    RegistrationClosed,
    InvalidAltcha(&'static str),
    InvalidRequest(String),
    UsernameTaken(String),
    RateLimited(u64),
    Internal(String),
}

#[derive(Serialize)]
struct ErrorResponse<'a> {
    error: &'a str,
    message: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    retry_after: Option<u64>,
}

impl DeltaChatError {
    pub fn status_code(&self) -> u16 {
        match self {
            Self::ModuleDisabled => 404,
            Self::Unauthorized => 401,
            Self::NotFound(_) => 404,
            Self::RegistrationClosed => 403,
            Self::InvalidAltcha(_) => 400,
            Self::InvalidRequest(_) => 400,
            Self::UsernameTaken(_) => 409,
            Self::RateLimited(_) => 429,
            Self::Internal(_) => 500,
        }
    }

    pub fn to_json(&self) -> String {
        let (error_code, message, retry_after) = match self {
            Self::ModuleDisabled => ("not_found", "DeltaChat module is disabled", None),
            Self::Unauthorized => ("unauthorized", "Authentication credentials invalid or missing", None),
            Self::NotFound(msg) => ("not_found", *msg, None),
            Self::RegistrationClosed => ("registration_closed", "Account registration is closed", None),
            Self::InvalidAltcha(msg) => ("invalid_altcha", *msg, None),
            Self::InvalidRequest(msg) => ("invalid_request", msg.as_str(), None),
            Self::UsernameTaken(name) => ("username_taken", name.as_str(), None),
            Self::RateLimited(retry) => ("rate_limited", "Too many requests. Try again later.", Some(*retry)),
            Self::Internal(detail) => {
                trc::error!("DeltaChat internal error: {detail}");
                ("internal_error", "An internal server error occurred", None)
            }
        };

        serde_json::to_string(&ErrorResponse {
            error: error_code,
            message,
            retry_after,
        })
        .unwrap_or_else(|_| r#"{"error":"internal_error","message":"Serialization failed"}"#.to_string())
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test -p deltachat error::tests`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add crates/deltachat/src/error.rs
git commit -m "feat(deltachat): implement safe DeltaChatError and JSON mapping"
```

---

### Task 4: Public Discovery & Verification Handlers

**Files:**
- Create: `crates/deltachat/src/models/mod.rs`
- Create: `crates/deltachat/src/models/system.rs`
- Create: `crates/deltachat/src/handlers/mod.rs`
- Create: `crates/deltachat/src/handlers/public.rs`
- Test: `crates/deltachat/tests/public_tests.rs`

**Interfaces:**
- Produces: `handle_health`, `handle_config`, `handle_domains`, `handle_username_check`, `is_valid_username`

- [ ] **Step 1: Write failing test in `crates/deltachat/tests/public_tests.rs`**

```rust
use deltachat::config::DeltaChatSettings;
use deltachat::handlers::public::{handle_config, handle_domains, handle_health, handle_username_check, is_valid_username};

#[test]
fn test_public_discovery_endpoints() {
    let settings = DeltaChatSettings::default();
    let start_time = std::time::Instant::now();

    // Health
    let health = handle_health(&settings, start_time).expect("health ok");
    assert_eq!(health.status, "healthy");

    // Config
    let config = handle_config(&settings).expect("config ok");
    assert_eq!(config.domain, "localhost");

    // Domains
    let domains = handle_domains(&settings).expect("domains ok");
    assert_eq!(domains.len(), 1);
    assert_eq!(domains[0].domain, "localhost");

    // Username check
    assert!(is_valid_username("valid_user-123"));
    assert!(!is_valid_username("admin"));
    assert!(!is_valid_username("bad/path"));
    assert!(!is_valid_username("bad..user"));
    assert!(!is_valid_username(".leadingdot"));

    let user_check = handle_username_check(&settings, "validuser", &[]).expect("user check ok");
    assert!(user_check.available);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p deltachat --test public_tests`  
Expected: FAIL

- [ ] **Step 3: Implement `models/system.rs` and `handlers/public.rs`**

`crates/deltachat/src/models/system.rs`:
```rust
use serde::{Deserialize, Serialize};
use crate::config::EndpointsConfig;

#[derive(Debug, Serialize, Deserialize)]
pub struct HealthResponse {
    pub status: &'static str,
    pub version: &'static str,
    pub uptime_seconds: u64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct AltchaPublicConfig {
    pub required: bool,
    pub max_number: u64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ConfigResponse {
    pub brand: String,
    pub domain: String,
    pub allowed_domains: Vec<String>,
    pub registration_open: bool,
    pub instant_accounts_enabled: bool,
    pub custom_accounts_enabled: bool,
    pub endpoints: EndpointsConfig,
    pub altcha: AltchaPublicConfig,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct DomainInfo {
    pub name: String,
    pub domain: String,
    pub is_default: bool,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct UsernameCheckResponse {
    pub username: String,
    pub available: bool,
}
```

`crates/deltachat/src/handlers/public.rs`:
```rust
use std::time::Instant;
use crate::config::DeltaChatSettings;
use crate::error::DeltaChatError;
use crate::models::system::{AltchaPublicConfig, ConfigResponse, DomainInfo, HealthResponse, UsernameCheckResponse};

const RESERVED_NAMES: &[&str] = &[
    "admin", "administrator", "root", "postmaster", "hostmaster",
    "abuse", "mailer-daemon", "nobody", "support", "security",
];

pub fn is_valid_username(u: &str) -> bool {
    u.len() >= 3
        && u.len() <= 32
        && !RESERVED_NAMES.contains(&u)
        && u.bytes().all(|b| matches!(b, b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.'))
        && !u.starts_with('.')
        && !u.ends_with('.')
        && !u.contains("..")
}

pub fn handle_health(settings: &DeltaChatSettings, start_time: Instant) -> Result<HealthResponse, DeltaChatError> {
    if !settings.enabled { return Err(DeltaChatError::ModuleDisabled); }
    Ok(HealthResponse {
        status: "healthy",
        version: "1.0.0-chatchi",
        uptime_seconds: start_time.elapsed().as_secs(),
    })
}

pub fn handle_config(settings: &DeltaChatSettings) -> Result<ConfigResponse, DeltaChatError> {
    if !settings.enabled { return Err(DeltaChatError::ModuleDisabled); }
    Ok(ConfigResponse {
        brand: settings.brand.clone(),
        domain: settings.domain.clone(),
        allowed_domains: settings.allowed_domains.clone(),
        registration_open: settings.registration_open,
        instant_accounts_enabled: settings.instant_accounts_enabled,
        custom_accounts_enabled: settings.custom_accounts_enabled,
        endpoints: settings.endpoints.clone(),
        altcha: AltchaPublicConfig {
            required: settings.altcha.required,
            max_number: settings.altcha.max_number,
        },
    })
}

pub fn handle_domains(settings: &DeltaChatSettings) -> Result<Vec<DomainInfo>, DeltaChatError> {
    if !settings.enabled { return Err(DeltaChatError::ModuleDisabled); }
    Ok(settings.allowed_domains.iter().map(|d| DomainInfo {
        name: d.clone(),
        domain: d.clone(),
        is_default: d == &settings.domain,
    }).collect())
}

pub fn handle_username_check(
    settings: &DeltaChatSettings,
    username: &str,
    existing_users: &[&str],
) -> Result<UsernameCheckResponse, DeltaChatError> {
    if !settings.enabled { return Err(DeltaChatError::ModuleDisabled); }
    let u = username.trim().to_ascii_lowercase();
    let available = is_valid_username(&u) && !existing_users.contains(&u.as_str());

    Ok(UsernameCheckResponse { username: u, available })
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test -p deltachat --test public_tests`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add crates/deltachat/src/models/ crates/deltachat/src/handlers/ crates/deltachat/tests/public_tests.rs crates/deltachat/src/lib.rs
git commit -m "feat(deltachat): implement public discovery and strict username validation"
```

---

### Task 5: Altcha PoW Engine with HMAC Challenge Binding & TTL Replay Cache

**Files:**
- Create: `crates/deltachat/src/security/mod.rs`
- Create: `crates/deltachat/src/security/altcha.rs`
- Test: `crates/deltachat/tests/altcha_tests.rs`

**Interfaces:**
- Produces: `AltchaEngine`, `AltchaChallenge`, `AltchaPayload`

- [ ] **Step 1: Write failing test in `crates/deltachat/tests/altcha_tests.rs`**

```rust
use deltachat::security::altcha::{AltchaEngine, AltchaPayload};

#[test]
fn test_altcha_pow_generation_and_verification() {
    let key = b"test-secret-key-1234567890123456".to_vec();
    let engine = AltchaEngine::new(key, 50_000);

    let challenge = engine.create_challenge();
    assert_eq!(challenge.algorithm, "SHA-256");

    let mut solved_number = None;
    for n in 0..=50_000 {
        if AltchaEngine::compute_hash(&challenge.salt, n) == challenge.challenge {
            solved_number = Some(n);
            break;
        }
    }
    let number = solved_number.expect("solution must exist");

    let payload = AltchaPayload {
        algorithm: challenge.algorithm,
        challenge: challenge.challenge,
        number,
        salt: challenge.salt,
        signature: challenge.signature,
    };
    assert!(engine.verify_payload(&payload).is_ok());
    // Replay must be rejected
    assert!(engine.verify_payload(&payload).is_err());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p deltachat --test altcha_tests`  
Expected: FAIL

- [ ] **Step 3: Implement `crates/deltachat/src/security/altcha.rs`**

```rust
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
use serde::{Deserialize, Serialize};
use utils::cache::CacheWithTtl;
use crate::error::DeltaChatError;

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AltchaChallenge {
    pub algorithm: String,
    pub challenge: String,
    pub salt: String,
    pub signature: String,
    pub max_number: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AltchaPayload {
    pub algorithm: String,
    pub challenge: String,
    pub number: u64,
    pub salt: String,
    pub signature: String,
}

pub struct AltchaEngine {
    secret_key: Vec<u8>,
    max_number: u64,
    replay_cache: CacheWithTtl<Box<str>, bool>,
}

impl AltchaEngine {
    pub fn new(secret_key: Vec<u8>, max_number: u64) -> Self {
        Self {
            secret_key,
            max_number,
            replay_cache: CacheWithTtl::new_estimated(10_000, 10_000),
        }
    }

    pub fn compute_signature(&self, salt: &str, challenge: &str) -> Vec<u8> {
        let mut mac = HmacSha256::new_from_slice(&self.secret_key)
            .expect("HMAC key length valid");
        mac.update(salt.as_bytes());
        mac.update(b":");
        mac.update(challenge.as_bytes());
        mac.finalize().into_bytes().to_vec()
    }

    pub fn create_challenge(&self) -> AltchaChallenge {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let salt = format!("{}:{:016x}", now, store::rand::random::<u64>());
        let number = store::rand::random::<u64>() % (self.max_number + 1);
        let challenge = Self::compute_hash(&salt, number);
        let signature = hex::encode(self.compute_signature(&salt, &challenge));

        AltchaChallenge {
            algorithm: "SHA-256".to_string(),
            challenge,
            salt,
            signature,
            max_number: self.max_number,
        }
    }

    pub fn compute_hash(salt: &str, number: u64) -> String {
        let mut hasher = Sha256::new();
        hasher.update(salt.as_bytes());
        hasher.update(number.to_string().as_bytes());
        hex::encode(hasher.finalize())
    }

    pub fn verify_payload(&self, payload: &AltchaPayload) -> Result<(), DeltaChatError> {
        if payload.algorithm != "SHA-256" {
            return Err(DeltaChatError::InvalidAltcha("Unsupported algorithm"));
        }
        if payload.number > self.max_number {
            return Err(DeltaChatError::InvalidAltcha("Solution number exceeds max_number"));
        }

        // 1. Timestamp validation (120s window)
        let parts: Vec<&str> = payload.salt.split(':').collect();
        if parts.is_empty() {
            return Err(DeltaChatError::InvalidAltcha("Malformed salt"));
        }
        let ts: u64 = parts[0]
            .parse()
            .map_err(|_| DeltaChatError::InvalidAltcha("Invalid timestamp in salt"))?;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        if now.abs_diff(ts) > 120 {
            return Err(DeltaChatError::InvalidAltcha("Challenge expired"));
        }

        // 2. Constant-time Signature Verification
        let sig_bytes = hex::decode(&payload.signature)
            .map_err(|_| DeltaChatError::InvalidAltcha("Malformed signature encoding"))?;
        let mut mac = HmacSha256::new_from_slice(&self.secret_key)
            .expect("HMAC key valid");
        mac.update(payload.salt.as_bytes());
        mac.update(b":");
        mac.update(payload.challenge.as_bytes());
        mac.verify_slice(&sig_bytes)
            .map_err(|_| DeltaChatError::InvalidAltcha("Invalid signature"))?;

        // 3. PoW hash check
        let expected_hash = Self::compute_hash(&payload.salt, payload.number);
        if expected_hash != payload.challenge {
            return Err(DeltaChatError::InvalidAltcha("Incorrect solution"));
        }

        // 4. Replay check with 120s TTL
        let key = payload.challenge.clone().into_boxed_str();
        if self.replay_cache.get(&key).is_some() {
            return Err(DeltaChatError::InvalidAltcha("Challenge already replayed"));
        }
        self.replay_cache.insert(key, true, Duration::from_secs(120));

        Ok(())
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test -p deltachat --test altcha_tests`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add crates/deltachat/src/security/ crates/deltachat/tests/altcha_tests.rs
git commit -m "feat(deltachat): implement Altcha PoW engine with CacheWithTtl"
```

---

### Task 6: DeltaChat Setup URI (`dclogin:`) Builder

**Files:**
- Create: `crates/deltachat/src/security/dclogin.rs`
- Test: `crates/deltachat/tests/dclogin_tests.rs`

**Interfaces:**
- Produces: `build_dclogin_uri(email, password, endpoints)`

- [ ] **Step 1: Write failing unit test for `dclogin` URI format**

```rust
use deltachat::config::{EndpointsConfig, MailEndpointConfig};
use deltachat::security::dclogin::build_dclogin_uri;

#[test]
fn test_build_dclogin_uri() {
    let endpoints = EndpointsConfig {
        imap: MailEndpointConfig { host: "mail.example.org".into(), port: 993, security: "ssl".into() },
        smtp: MailEndpointConfig { host: "mail.example.org".into(), port: 465, security: "ssl".into() },
    };
    let uri = build_dclogin_uri("user@example.org", "pass123!", &endpoints);
    assert!(uri.starts_with("dclogin:user@example.org/?"));
    assert!(uri.contains("p=pass123%21"));
    assert!(uri.contains("ih=mail.example.org"));
    assert!(uri.contains("ip=993"));
    assert!(uri.contains("v=1"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p deltachat --test dclogin_tests`  
Expected: FAIL

- [ ] **Step 3: Implement `crates/deltachat/src/security/dclogin.rs`**

```rust
use crate::config::EndpointsConfig;

pub fn build_dclogin_uri(email: &str, password: &str, endpoints: &EndpointsConfig) -> String {
    let query = form_urlencoded::Serializer::new(String::new())
        .append_pair("p", password)
        .append_pair("v", "1")
        .append_pair("ih", &endpoints.imap.host)
        .append_pair("ip", &endpoints.imap.port.to_string())
        .append_pair("is", &endpoints.imap.security)
        .append_pair("sh", &endpoints.smtp.host)
        .append_pair("sp", &endpoints.smtp.port.to_string())
        .append_pair("ss", &endpoints.smtp.security)
        .append_pair("ic", "3")
        .finish();

    format!("dclogin:{}?{}", email, query)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test -p deltachat --test dclogin_tests`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add crates/deltachat/src/security/dclogin.rs crates/deltachat/tests/dclogin_tests.rs
git commit -m "feat(deltachat): implement dclogin URI builder using form_urlencoded"
```

---

### Task 7: Shared Mailbox Service & Public Account Provisioning

**Files:**
- Create: `crates/deltachat/src/models/accounts.rs`
- Create: `crates/deltachat/src/services/mod.rs`
- Create: `crates/deltachat/src/services/mailbox_service.rs`
- Test: `crates/deltachat/tests/mailbox_tests.rs`

**Interfaces:**
- Produces: `MailboxService`, `InstantAccountRequest`, `CustomAccountRequest`, `AccountResponse`

- [ ] **Step 1: Write failing test in `crates/deltachat/tests/mailbox_tests.rs`**

```rust
use deltachat::config::DeltaChatSettings;
use deltachat::security::altcha::AltchaEngine;
use deltachat::services::mailbox_service::MailboxService;
use deltachat::models::accounts::{CustomAccountRequest, InstantAccountRequest};

#[tokio::test]
async fn test_instant_and_custom_provisioning() {
    let settings = DeltaChatSettings::default();
    let engine = AltchaEngine::new(b"test-key".to_vec(), 50_000);
    let service = MailboxService::new();

    // Instant
    let instant_res = service.provision_instant(&settings, &engine, InstantAccountRequest { altcha_payload: None }).await
        .expect("instant ok");
    assert!(instant_res.email.starts_with("dc_"));
    assert!(instant_res.dclogin_link.starts_with("dclogin:dc_"));

    // Custom
    let custom_res = service.provision_custom(&settings, &engine, None, CustomAccountRequest {
        username: "testuser".into(),
        domain: "localhost".into(),
        password: "MySecurePassword123#".into(),
        altcha_payload: None,
    }).await.expect("custom ok");
    assert_eq!(custom_res.email, "testuser@localhost");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p deltachat --test mailbox_tests`  
Expected: FAIL

- [ ] **Step 3: Implement `models/accounts.rs` and `services/mailbox_service.rs`**

`crates/deltachat/src/models/accounts.rs`:
```rust
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
pub struct InstantAccountRequest {
    pub altcha_payload: Option<String>,
}

impl std::fmt::Debug for InstantAccountRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("InstantAccountRequest")
            .field("has_altcha", &self.altcha_payload.is_some())
            .finish()
    }
}

#[derive(Deserialize)]
pub struct CustomAccountRequest {
    pub username: String,
    pub domain: String,
    pub password: String,
    pub altcha_payload: Option<String>,
}

impl std::fmt::Debug for CustomAccountRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CustomAccountRequest")
            .field("username", &self.username)
            .field("domain", &self.domain)
            .field("password", &"[REDACTED]")
            .finish()
    }
}

#[derive(Serialize)]
pub struct AccountResponse {
    pub account_id: String,
    pub email: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub password: Option<String>,
    pub dclogin_link: String,
    pub account_type: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub quota_mb: Option<u64>,
}

impl std::fmt::Debug for AccountResponse {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AccountResponse")
            .field("account_id", &self.account_id)
            .field("email", &self.email)
            .field("password", &"[REDACTED]")
            .field("dclogin_link", &"[REDACTED]")
            .finish()
    }
}
```

`crates/deltachat/src/services/mailbox_service.rs`:
```rust
use std::collections::HashMap;
use parking_lot::RwLock;
use serde::Serialize;
use crate::config::DeltaChatSettings;
use crate::error::DeltaChatError;
use crate::handlers::public::is_valid_username;
use crate::models::accounts::{AccountResponse, CustomAccountRequest, InstantAccountRequest};
use crate::security::altcha::{AltchaEngine, AltchaPayload};
use crate::security::dclogin::build_dclogin_uri;

#[derive(Clone, Debug, Serialize)]
pub struct MailboxRecord {
    pub id: String,
    pub owner_id: Option<String>,
    pub email: String,
    pub domain: String,
    pub status: String,
    #[serde(skip)]
    pub password_hash: String,
}

pub struct MailboxService {
    mailboxes: RwLock<HashMap<String, MailboxRecord>>,
}

impl MailboxService {
    pub fn new() -> Self {
        Self { mailboxes: RwLock::new(HashMap::new()) }
    }

    pub fn generate_secure_password(len: usize) -> String {
        const CHARSET: &[u8] = b"abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789!@#$%^&*";
        (0..len).map(|_| {
            let idx = store::rand::random::<usize>() % CHARSET.len();
            CHARSET[idx] as char
        }).collect()
    }

    pub async fn provision_instant(
        &self,
        settings: &DeltaChatSettings,
        engine: &AltchaEngine,
        req: InstantAccountRequest,
    ) -> Result<AccountResponse, DeltaChatError> {
        if !settings.enabled { return Err(DeltaChatError::ModuleDisabled); }
        if !settings.registration_open || !settings.instant_accounts_enabled {
            return Err(DeltaChatError::RegistrationClosed);
        }
        if settings.altcha.required {
            let raw = req.altcha_payload.ok_or(DeltaChatError::InvalidAltcha("Altcha required"))?;
            let payload: AltchaPayload = serde_json::from_str(&raw)
                .map_err(|_| DeltaChatError::InvalidAltcha("Malformed Altcha JSON"))?;
            engine.verify_payload(&payload)?;
        }

        let random_hex = format!("{:012x}", store::rand::random::<u64>() & 0xffffffffffff);
        let email = format!("dc_{}@{}", random_hex, settings.domain);
        let password = Self::generate_secure_password(24);
        let id = format!("acc_{:016x}", store::rand::random::<u64>());
        let dclogin_link = build_dclogin_uri(&email, &password, &settings.endpoints);

        let password_hash = directory::core::secret::hash_secret(
            registry::schema::enums::PasswordHashAlgorithm::Argon2id,
            password.as_bytes().to_vec(),
        ).await.map_err(|e| DeltaChatError::Internal(e.to_string()))?;

        let mut lock = self.mailboxes.write();
        lock.insert(id.clone(), MailboxRecord {
            id: id.clone(),
            owner_id: None,
            email: email.clone(),
            domain: settings.domain.clone(),
            status: "active".into(),
            password_hash,
        });

        Ok(AccountResponse {
            account_id: id,
            email,
            password: Some(password),
            dclogin_link,
            account_type: "instant",
            quota_mb: Some(settings.default_quota_mb),
        })
    }

    pub async fn provision_custom(
        &self,
        settings: &DeltaChatSettings,
        engine: &AltchaEngine,
        owner_id: Option<String>,
        req: CustomAccountRequest,
    ) -> Result<AccountResponse, DeltaChatError> {
        if !settings.enabled { return Err(DeltaChatError::ModuleDisabled); }
        if !settings.registration_open || !settings.custom_accounts_enabled {
            return Err(DeltaChatError::RegistrationClosed);
        }

        let username = req.username.trim().to_ascii_lowercase();
        let domain = req.domain.trim().to_ascii_lowercase();

        if !is_valid_username(&username) {
            return Err(DeltaChatError::InvalidRequest("Invalid username format".into()));
        }
        if !settings.allowed_domains.iter().any(|d| d.eq_ignore_ascii_case(&domain)) {
            return Err(DeltaChatError::InvalidRequest(format!("Domain '{}' not allowed", domain)));
        }
        if req.password.len() < 10 {
            return Err(DeltaChatError::InvalidRequest("Password must be at least 10 characters".into()));
        }

        if settings.altcha.required {
            let raw = req.altcha_payload.ok_or(DeltaChatError::InvalidAltcha("Altcha required"))?;
            let payload: AltchaPayload = serde_json::from_str(&raw)
                .map_err(|_| DeltaChatError::InvalidAltcha("Malformed Altcha JSON"))?;
            engine.verify_payload(&payload)?;
        }

        let email = format!("{}@{}", username, domain);
        let id = format!("mbx_{:016x}", store::rand::random::<u64>());

        let password_hash = directory::core::secret::hash_secret(
            registry::schema::enums::PasswordHashAlgorithm::Argon2id,
            req.password.as_bytes().to_vec(),
        ).await.map_err(|e| DeltaChatError::Internal(e.to_string()))?;

        let mut lock = self.mailboxes.write();
        if lock.values().any(|m| m.email == email) {
            return Err(DeltaChatError::UsernameTaken(username));
        }

        lock.insert(id.clone(), MailboxRecord {
            id: id.clone(),
            owner_id,
            email: email.clone(),
            domain,
            status: "active".into(),
            password_hash,
        });

        let dclogin_link = build_dclogin_uri(&email, &req.password, &settings.endpoints);
        Ok(AccountResponse {
            account_id: id,
            email,
            password: None,
            dclogin_link,
            account_type: "custom",
            quota_mb: None,
        })
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test -p deltachat --test mailbox_tests`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add crates/deltachat/src/models/accounts.rs crates/deltachat/src/services/ crates/deltachat/tests/mailbox_tests.rs
git commit -m "feat(deltachat): implement async MailboxService provisioning with Argon2id"
```

---

### Task 8: Product Identity & Bearer Token Authentication

**Files:**
- Create: `crates/deltachat/src/models/auth.rs`
- Create: `crates/deltachat/src/security/token.rs`
- Create: `crates/deltachat/src/services/user_service.rs`
- Test: `crates/deltachat/tests/auth_tests.rs`

**Interfaces:**
- Produces: `UserService`, `TokenEngine`, `AuthResponse`, `UserDto`

- [ ] **Step 1: Write failing test in `crates/deltachat/tests/auth_tests.rs`**

```rust
use deltachat::services::user_service::UserService;
use deltachat::models::auth::{LoginRequest, RegisterRequest};

#[tokio::test]
async fn test_user_register_login_and_token() {
    let service = UserService::new();

    // Register
    let auth = service.register(RegisterRequest {
        username: "erfan".into(),
        email: "erfan@example.com".into(),
        password: "ProductPassword123!".into(),
    }).await.expect("register ok");
    assert_eq!(auth.user.username, "erfan");
    assert!(auth.token.starts_with("dcat_"));

    // Verify token
    let user = service.authenticate_token(&auth.token).expect("token valid");
    assert_eq!(user.id, auth.user.id);

    // Login
    let login_auth = service.login(LoginRequest {
        username: "erfan".into(),
        password: "ProductPassword123!".into(),
    }).await.expect("login ok");
    assert_eq!(login_auth.user.id, auth.user.id);

    // Logout
    service.logout(&login_auth.token);
    assert!(service.authenticate_token(&login_auth.token).is_none());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p deltachat --test auth_tests`  
Expected: FAIL

- [ ] **Step 3: Implement `models/auth.rs`, `security/token.rs`, and `services/user_service.rs`**

`crates/deltachat/src/models/auth.rs`:
```rust
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
pub struct RegisterRequest {
    pub username: String,
    pub email: String,
    pub password: String,
}

impl std::fmt::Debug for RegisterRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RegisterRequest")
            .field("username", &self.username)
            .field("email", &self.email)
            .field("password", &"[REDACTED]")
            .finish()
    }
}

#[derive(Deserialize)]
pub struct LoginRequest {
    pub username: String,
    pub password: String,
}

impl std::fmt::Debug for LoginRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LoginRequest")
            .field("username", &self.username)
            .field("password", &"[REDACTED]")
            .finish()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserDto {
    pub id: String,
    pub username: String,
    pub email: String,
}

#[derive(Serialize)]
pub struct AuthResponse {
    pub token: String,
    pub user: UserDto,
}
```

`crates/deltachat/src/security/token.rs`:
```rust
use std::time::Duration;
use utils::cache::CacheWithTtl;

pub struct TokenEngine {
    tokens: CacheWithTtl<Box<str>, Box<str>>,
}

impl TokenEngine {
    pub fn new() -> Self {
        Self { tokens: CacheWithTtl::new_estimated(10_000, 10_000) }
    }

    pub fn issue_token(&self, user_id: &str) -> String {
        let token = format!("dcat_{:032x}", store::rand::random::<u128>());
        self.tokens.insert(token.clone().into_boxed_str(), user_id.to_string().into_boxed_str(), Duration::from_secs(86400 * 30));
        token
    }

    pub fn validate_token(&self, token: &str) -> Option<String> {
        let key = token.to_string().into_boxed_str();
        self.tokens.get(&key).map(|v| v.to_string())
    }

    pub fn revoke_token(&self, token: &str) {
        let key = token.to_string().into_boxed_str();
        self.tokens.remove(&key);
    }
}
```

`crates/deltachat/src/services/user_service.rs`:
```rust
use std::collections::HashMap;
use parking_lot::RwLock;
use crate::error::DeltaChatError;
use crate::handlers::public::is_valid_username;
use crate::models::auth::{AuthResponse, LoginRequest, RegisterRequest, UserDto};
use crate::security::token::TokenEngine;

struct UserRecord {
    id: String,
    username: String,
    email: String,
    password_hash: String,
}

pub struct UserService {
    users: RwLock<HashMap<String, UserRecord>>,
    tokens: TokenEngine,
}

impl UserService {
    pub fn new() -> Self {
        Self {
            users: RwLock::new(HashMap::new()),
            tokens: TokenEngine::new(),
        }
    }

    pub async fn register(&self, req: RegisterRequest) -> Result<AuthResponse, DeltaChatError> {
        let username = req.username.trim().to_ascii_lowercase();
        if !is_valid_username(&username) {
            return Err(DeltaChatError::InvalidRequest("Invalid username format".into()));
        }

        let password_hash = directory::core::secret::hash_secret(
            registry::schema::enums::PasswordHashAlgorithm::Argon2id,
            req.password.as_bytes().to_vec(),
        ).await.map_err(|e| DeltaChatError::Internal(e.to_string()))?;

        let mut lock = self.users.write();
        if lock.values().any(|u| u.username == username || u.email == req.email) {
            return Err(DeltaChatError::UsernameTaken(username));
        }

        let id = format!("usr_{:016x}", store::rand::random::<u64>());
        let user = UserRecord {
            id: id.clone(),
            username: username.clone(),
            email: req.email.clone(),
            password_hash,
        };
        lock.insert(id.clone(), user);

        let token = self.tokens.issue_token(&id);
        Ok(AuthResponse {
            token,
            user: UserDto { id, username, email: req.email },
        })
    }

    pub async fn login(&self, req: LoginRequest) -> Result<AuthResponse, DeltaChatError> {
        let username = req.username.trim().to_ascii_lowercase();
        let (user_id, email, password_hash) = {
            let lock = self.users.read();
            let user = lock.values().find(|u| u.username == username)
                .ok_or(DeltaChatError::Unauthorized)?;
            (user.id.clone(), user.email.clone(), user.password_hash.clone())
        };

        let valid = directory::core::secret::verify_secret_hash(&password_hash, req.password.as_bytes())
            .await
            .unwrap_or(false);
        if !valid {
            return Err(DeltaChatError::Unauthorized);
        }

        let token = self.tokens.issue_token(&user_id);
        Ok(AuthResponse {
            token,
            user: UserDto { id: user_id, username, email },
        })
    }

    pub fn logout(&self, token: &str) {
        self.tokens.revoke_token(token);
    }

    pub fn authenticate_token(&self, token: &str) -> Option<UserDto> {
        let user_id = self.tokens.validate_token(token)?;
        let lock = self.users.read();
        let user = lock.get(&user_id)?;
        Some(UserDto { id: user.id.clone(), username: user.username.clone(), email: user.email.clone() })
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test -p deltachat --test auth_tests`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add crates/deltachat/src/models/auth.rs crates/deltachat/src/security/token.rs crates/deltachat/src/services/user_service.rs crates/deltachat/tests/auth_tests.rs
git commit -m "feat(deltachat): implement async UserService with token auth"
```

---

### Task 9: Authenticated Mailbox Lifecycle Management

**Files:**
- Modify: `crates/deltachat/src/services/mailbox_service.rs`
- Test: `crates/deltachat/tests/mailbox_tests.rs`

**Interfaces:**
- Produces: `list_for_owner`, `get_for_owner`, `update_password_for_owner`, `suspend_for_owner`, `resume_for_owner`, `delete_for_owner`

- [ ] **Step 1: Write failing test in `crates/deltachat/tests/mailbox_tests.rs`**

```rust
#[tokio::test]
async fn test_mailbox_lifecycle() {
    let settings = DeltaChatSettings::default();
    let engine = AltchaEngine::new(b"key".to_vec(), 50_000);
    let service = MailboxService::new();
    let owner_id = "usr_01";

    // Provision
    let account = service.provision_custom(&settings, &engine, Some(owner_id.into()), CustomAccountRequest {
        username: "sales".into(),
        domain: "localhost".into(),
        password: "InitialPassword123!".into(),
        altcha_payload: None,
    }).await.expect("provision ok");

    // List
    let list = service.list_for_owner(owner_id);
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].id, account.account_id);

    // Detail
    let detail = service.get_for_owner(owner_id, &account.account_id).expect("get ok");
    assert_eq!(detail.status, "active");

    // Suspend & Resume
    let suspended = service.suspend_for_owner(owner_id, &account.account_id).expect("suspend ok");
    assert_eq!(suspended.status, "suspended");

    let resumed = service.resume_for_owner(owner_id, &account.account_id).expect("resume ok");
    assert_eq!(resumed.status, "active");

    // Delete
    assert!(service.delete_for_owner(owner_id, &account.account_id).is_ok());
    assert!(service.get_for_owner(owner_id, &account.account_id).is_none());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p deltachat --test mailbox_tests`  
Expected: FAIL

- [ ] **Step 3: Implement lifecycle methods in `MailboxService`**

Add to `crates/deltachat/src/services/mailbox_service.rs`:
```rust
impl MailboxService {
    pub fn list_for_owner(&self, owner_id: &str) -> Vec<MailboxRecord> {
        let lock = self.mailboxes.read();
        lock.values().filter(|m| m.owner_id.as_deref() == Some(owner_id)).cloned().collect()
    }

    pub fn get_for_owner(&self, owner_id: &str, mailbox_id: &str) -> Option<MailboxRecord> {
        let lock = self.mailboxes.read();
        let record = lock.get(mailbox_id)?;
        if record.owner_id.as_deref() == Some(owner_id) { Some(record.clone()) } else { None }
    }

    pub async fn update_password_for_owner(
        &self,
        owner_id: &str,
        mailbox_id: &str,
        new_password: &str,
    ) -> Result<(), DeltaChatError> {
        if new_password.len() < 10 {
            return Err(DeltaChatError::InvalidRequest("Password must be at least 10 characters".into()));
        }
        let password_hash = directory::core::secret::hash_secret(
            registry::schema::enums::PasswordHashAlgorithm::Argon2id,
            new_password.as_bytes().to_vec(),
        ).await.map_err(|e| DeltaChatError::Internal(e.to_string()))?;

        let mut lock = self.mailboxes.write();
        let record = lock.get_mut(mailbox_id).ok_or(DeltaChatError::NotFound("Mailbox not found"))?;
        if record.owner_id.as_deref() != Some(owner_id) {
            return Err(DeltaChatError::NotFound("Mailbox not found"));
        }
        record.password_hash = password_hash;
        Ok(())
    }

    pub fn suspend_for_owner(&self, owner_id: &str, mailbox_id: &str) -> Result<MailboxRecord, DeltaChatError> {
        let mut lock = self.mailboxes.write();
        let record = lock.get_mut(mailbox_id).ok_or(DeltaChatError::NotFound("Mailbox not found"))?;
        if record.owner_id.as_deref() != Some(owner_id) {
            return Err(DeltaChatError::NotFound("Mailbox not found"));
        }
        record.status = "suspended".into();
        Ok(record.clone())
    }

    pub fn resume_for_owner(&self, owner_id: &str, mailbox_id: &str) -> Result<MailboxRecord, DeltaChatError> {
        let mut lock = self.mailboxes.write();
        let record = lock.get_mut(mailbox_id).ok_or(DeltaChatError::NotFound("Mailbox not found"))?;
        if record.owner_id.as_deref() != Some(owner_id) {
            return Err(DeltaChatError::NotFound("Mailbox not found"));
        }
        record.status = "active".into();
        Ok(record.clone())
    }

    pub fn delete_for_owner(&self, owner_id: &str, mailbox_id: &str) -> Result<(), DeltaChatError> {
        let mut lock = self.mailboxes.write();
        let record = lock.get(mailbox_id).ok_or(DeltaChatError::NotFound("Mailbox not found"))?;
        if record.owner_id.as_deref() != Some(owner_id) {
            return Err(DeltaChatError::NotFound("Mailbox not found"));
        }
        lock.remove(mailbox_id);
        Ok(())
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test -p deltachat --test mailbox_tests`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add crates/deltachat/src/services/mailbox_service.rs crates/deltachat/tests/mailbox_tests.rs
git commit -m "feat(deltachat): implement mailbox lifecycle operations for owner"
```

---

### Task 10: WebXDC App Store & Static Asset Delivery

**Files:**
- Create: `crates/deltachat/src/models/apps.rs`
- Create: `crates/deltachat/src/handlers/apps.rs`
- Test: `crates/deltachat/tests/apps_tests.rs`

**Interfaces:**
- Produces: `WebxdcApp`, `WebxdcCatalog`, `handle_get_apps`

- [ ] **Step 1: Write failing unit test for app catalog**

```rust
use deltachat::config::DeltaChatSettings;
use deltachat::handlers::apps::handle_get_apps;

#[test]
fn test_webxdc_catalog() {
    let settings = DeltaChatSettings::default();
    let catalog = handle_get_apps(&settings).expect("apps ok");
    assert_eq!(catalog.version, "1.0");
    assert!(!catalog.apps.is_empty());
    assert_eq!(catalog.apps[0].app_id, "chat.delta.webxdc.chess");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p deltachat --test apps_tests`  
Expected: FAIL

- [ ] **Step 3: Implement `models/apps.rs` and `handlers/apps.rs`**

`crates/deltachat/src/models/apps.rs`:
```rust
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WebxdcApp {
    pub app_id: String,
    pub name: String,
    pub version: String,
    pub tag_name: String,
    pub date: String,
    pub description: String,
    pub author: String,
    pub size: u64,
    pub icon_url: String,
    pub download_url: String,
    pub source_code_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WebxdcCatalog {
    pub version: String,
    pub apps: Vec<WebxdcApp>,
}
```

`crates/deltachat/src/handlers/apps.rs`:
```rust
use crate::config::DeltaChatSettings;
use crate::error::DeltaChatError;
use crate::models::apps::{WebxdcApp, WebxdcCatalog};

pub fn handle_get_apps(settings: &DeltaChatSettings) -> Result<WebxdcCatalog, DeltaChatError> {
    if !settings.enabled { return Err(DeltaChatError::ModuleDisabled); }
    Ok(WebxdcCatalog {
        version: "1.0".into(),
        apps: vec![
            WebxdcApp {
                app_id: "chat.delta.webxdc.chess".into(),
                name: "Chess".into(),
                version: "1.4.2".into(),
                tag_name: "v1.4.2".into(),
                date: "2026-08-01T12:00:00Z".into(),
                description: "Play chess with contacts in DeltaChat.".into(),
                author: "DeltaChat Community".into(),
                size: 420_000,
                icon_url: "/apps/xdcstore/icons/chess.png".into(),
                download_url: "/apps/xdcstore/packages/chess.xdc".into(),
                source_code_url: Some("https://github.com/webxdc/chess".into()),
            },
        ],
    })
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test -p deltachat --test apps_tests`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add crates/deltachat/src/models/apps.rs crates/deltachat/src/handlers/apps.rs crates/deltachat/tests/apps_tests.rs
git commit -m "feat(deltachat): implement WebXDC app catalog handler"
```

---

### Task 11: Unified HTTP Router Dispatcher

**Files:**
- Create: `crates/deltachat/src/router.rs`
- Modify: `crates/deltachat/src/lib.rs`
- Test: `crates/deltachat/tests/router_tests.rs`

**Interfaces:**
- Produces: `DeltaChatRouter::dispatch(method, path, auth_header, body)` with 64KB body caps

- [ ] **Step 1: Write failing test in `crates/deltachat/tests/router_tests.rs`**

```rust
use deltachat::config::DeltaChatSettings;
use deltachat::router::DeltaChatRouter;

#[tokio::test]
async fn test_router_dispatch_public_and_auth() {
    let router = DeltaChatRouter::new(DeltaChatSettings::default());

    // Public health
    let (code, body) = router.dispatch("GET", "/api/v1/health", None, None).await;
    assert_eq!(code, 200);
    assert!(body.contains("healthy"));

    // Register user
    let reg_body = serde_json::to_vec(&serde_json::json!({
        "username": "bob", "email": "bob@example.com", "password": "Password12345!"
    })).unwrap();
    let (code, body) = router.dispatch("POST", "/api/v1/auth/register", None, Some(&reg_body)).await;
    assert_eq!(code, 201);
    let val: serde_json::Value = serde_json::from_str(&body).unwrap();
    let token = val["token"].as_str().unwrap();

    // Authenticated me
    let auth_header = format!("Bearer {token}");
    let (code, body) = router.dispatch("GET", "/api/v1/me", Some(&auth_header), None).await;
    assert_eq!(code, 200);
    assert!(body.contains("bob"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p deltachat --test router_tests`  
Expected: FAIL

- [ ] **Step 3: Implement `crates/deltachat/src/router.rs`**

```rust
use std::time::Instant;
use crate::config::DeltaChatSettings;
use crate::handlers::apps::handle_get_apps;
use crate::handlers::public::{handle_config, handle_domains, handle_health, handle_username_check};
use crate::models::accounts::{CustomAccountRequest, InstantAccountRequest};
use crate::models::auth::{LoginRequest, RegisterRequest};
use crate::security::altcha::AltchaEngine;
use crate::services::mailbox_service::MailboxService;
use crate::services::user_service::UserService;

const MAX_PAYLOAD_BYTES: usize = 64 * 1024;

pub struct DeltaChatRouter {
    settings: DeltaChatSettings,
    altcha_engine: AltchaEngine,
    mailbox_service: MailboxService,
    user_service: UserService,
    start_time: Instant,
}

impl DeltaChatRouter {
    pub fn new(settings: DeltaChatSettings) -> Self {
        let key = settings.altcha.resolved_hmac_key();
        let altcha_engine = AltchaEngine::new(key, settings.altcha.max_number);
        Self {
            settings,
            altcha_engine,
            mailbox_service: MailboxService::new(),
            user_service: UserService::new(),
            start_time: Instant::now(),
        }
    }

    pub async fn dispatch(
        &self,
        method: &str,
        path: &str,
        auth_header: Option<&str>,
        body: Option<&[u8]>,
    ) -> (u16, String) {
        if !self.settings.enabled {
            return (404, r#"{"error":"not_found","message":"DeltaChat module disabled"}"#.into());
        }

        if let Some(b) = body {
            if b.len() > MAX_PAYLOAD_BYTES {
                return (413, r#"{"error":"payload_too_large","message":"Exceeds 64KB limit"}"#.into());
            }
        }

        let p_raw = path.strip_prefix("/api/v1").or_else(|| path.strip_prefix("/api")).unwrap_or(path);
        let p = p_raw.trim_end_matches('/');
        let token = auth_header.and_then(|h| h.strip_prefix("Bearer ").or_else(|| h.strip_prefix("Token ")));

        match (method, p) {
            ("GET", "/health") => match handle_health(&self.settings, self.start_time) {
                Ok(r) => (200, serde_json::to_string(&r).unwrap()),
                Err(e) => (e.status_code(), e.to_json()),
            },
            ("GET", "/config") => match handle_config(&self.settings) {
                Ok(r) => (200, serde_json::to_string(&r).unwrap()),
                Err(e) => (e.status_code(), e.to_json()),
            },
            ("GET", "/domains") => match handle_domains(&self.settings) {
                Ok(r) => (200, serde_json::to_string(&r).unwrap()),
                Err(e) => (e.status_code(), e.to_json()),
            },
            ("GET", path) if path.starts_with("/username/") => {
                let name = path.strip_prefix("/username/").unwrap();
                match handle_username_check(&self.settings, name, &[]) {
                    Ok(r) => (200, serde_json::to_string(&r).unwrap()),
                    Err(e) => (e.status_code(), e.to_json()),
                }
            }
            ("GET", "/altcha/challenge") => {
                (200, serde_json::to_string(&self.altcha_engine.create_challenge()).unwrap())
            }
            ("POST", "/accounts/instant") => {
                let req: InstantAccountRequest = match body {
                    Some(b) => match serde_json::from_slice(b) {
                        Ok(r) => r,
                        Err(_) => return (400, r#"{"error":"invalid_json"}"#.into()),
                    },
                    None => InstantAccountRequest { altcha_payload: None },
                };
                match self.mailbox_service.provision_instant(&self.settings, &self.altcha_engine, req).await {
                    Ok(r) => (201, serde_json::to_string(&r).unwrap()),
                    Err(e) => (e.status_code(), e.to_json()),
                }
            }
            ("POST", "/accounts/custom" | "/signup") => {
                let Some(bytes) = body else { return (400, r#"{"error":"missing_body"}"#.into()); };
                let req: CustomAccountRequest = match serde_json::from_slice(bytes) {
                    Ok(r) => r,
                    Err(_) => return (400, r#"{"error":"invalid_json"}"#.into()),
                };
                match self.mailbox_service.provision_custom(&self.settings, &self.altcha_engine, None, req).await {
                    Ok(r) => (201, serde_json::to_string(&r).unwrap()),
                    Err(e) => (e.status_code(), e.to_json()),
                }
            }
            ("POST", "/auth/register") => {
                let Some(bytes) = body else { return (400, r#"{"error":"missing_body"}"#.into()); };
                let req: RegisterRequest = match serde_json::from_slice(bytes) {
                    Ok(r) => r,
                    Err(_) => return (400, r#"{"error":"invalid_json"}"#.into()),
                };
                match self.user_service.register(req).await {
                    Ok(r) => (201, serde_json::to_string(&r).unwrap()),
                    Err(e) => (e.status_code(), e.to_json()),
                }
            }
            ("POST", "/auth/login") => {
                let Some(bytes) = body else { return (400, r#"{"error":"missing_body"}"#.into()); };
                let req: LoginRequest = match serde_json::from_slice(bytes) {
                    Ok(r) => r,
                    Err(_) => return (400, r#"{"error":"invalid_json"}"#.into()),
                };
                match self.user_service.login(req).await {
                    Ok(r) => (200, serde_json::to_string(&r).unwrap()),
                    Err(e) => (e.status_code(), e.to_json()),
                }
            }
            ("POST", "/auth/logout") => {
                if let Some(t) = token { self.user_service.logout(t); }
                (204, "".into())
            }
            ("GET", "/me") => {
                let Some(t) = token else { return (401, r#"{"error":"unauthorized"}"#.into()); };
                match self.user_service.authenticate_token(t) {
                    Some(u) => (200, serde_json::to_string(&u).unwrap()),
                    None => (401, r#"{"error":"unauthorized"}"#.into()),
                }
            }
            ("GET", "/mailboxes") => {
                let Some(t) = token else { return (401, r#"{"error":"unauthorized"}"#.into()); };
                let Some(u) = self.user_service.authenticate_token(t) else { return (401, r#"{"error":"unauthorized"}"#.into()); };
                let list = self.mailbox_service.list_for_owner(&u.id);
                (200, serde_json::to_string(&list).unwrap())
            }
            ("POST", "/mailboxes") => {
                let Some(t) = token else { return (401, r#"{"error":"unauthorized"}"#.into()); };
                let Some(u) = self.user_service.authenticate_token(t) else { return (401, r#"{"error":"unauthorized"}"#.into()); };
                let Some(bytes) = body else { return (400, r#"{"error":"missing_body"}"#.into()); };
                let req: CustomAccountRequest = match serde_json::from_slice(bytes) {
                    Ok(r) => r,
                    Err(_) => return (400, r#"{"error":"invalid_json"}"#.into()),
                };
                match self.mailbox_service.provision_custom(&self.settings, &self.altcha_engine, Some(u.id), req).await {
                    Ok(r) => (201, serde_json::to_string(&r).unwrap()),
                    Err(e) => (e.status_code(), e.to_json()),
                }
            }
            ("GET", path) if path.starts_with("/mailboxes/") => {
                let Some(t) = token else { return (401, r#"{"error":"unauthorized"}"#.into()); };
                let Some(u) = self.user_service.authenticate_token(t) else { return (401, r#"{"error":"unauthorized"}"#.into()); };
                let id = path.strip_prefix("/mailboxes/").unwrap();
                match self.mailbox_service.get_for_owner(&u.id, id) {
                    Some(m) => (200, serde_json::to_string(&m).unwrap()),
                    None => (404, r#"{"error":"not_found","message":"Mailbox not found"}"#.into()),
                }
            }
            ("POST", path) if path.starts_with("/mailboxes/") && path.ends_with("/password") => {
                let Some(t) = token else { return (401, r#"{"error":"unauthorized"}"#.into()); };
                let Some(u) = self.user_service.authenticate_token(t) else { return (401, r#"{"error":"unauthorized"}"#.into()); };
                let id = path.strip_prefix("/mailboxes/").unwrap().strip_suffix("/password").unwrap();
                let Some(bytes) = body else { return (400, r#"{"error":"missing_body"}"#.into()); };
                let Ok(json) = serde_json::from_slice::<serde_json::Value>(bytes) else { return (400, r#"{"error":"invalid_json"}"#.into()); };
                let Some(new_pass) = json["password"].as_str() else { return (400, r#"{"error":"invalid_request"}"#.into()); };
                match self.mailbox_service.update_password_for_owner(&u.id, id, new_pass).await {
                    Ok(_) => (200, r#"{"status":"success","message":"Password updated"}"#.into()),
                    Err(e) => (e.status_code(), e.to_json()),
                }
            }
            ("POST", path) if path.starts_with("/mailboxes/") && path.ends_with("/suspend") => {
                let Some(t) = token else { return (401, r#"{"error":"unauthorized"}"#.into()); };
                let Some(u) = self.user_service.authenticate_token(t) else { return (401, r#"{"error":"unauthorized"}"#.into()); };
                let id = path.strip_prefix("/mailboxes/").unwrap().strip_suffix("/suspend").unwrap();
                match self.mailbox_service.suspend_for_owner(&u.id, id) {
                    Ok(m) => (200, serde_json::to_string(&m).unwrap()),
                    Err(e) => (e.status_code(), e.to_json()),
                }
            }
            ("POST", path) if path.starts_with("/mailboxes/") && path.ends_with("/resume") => {
                let Some(t) = token else { return (401, r#"{"error":"unauthorized"}"#.into()); };
                let Some(u) = self.user_service.authenticate_token(t) else { return (401, r#"{"error":"unauthorized"}"#.into()); };
                let id = path.strip_prefix("/mailboxes/").unwrap().strip_suffix("/resume").unwrap();
                match self.mailbox_service.resume_for_owner(&u.id, id) {
                    Ok(m) => (200, serde_json::to_string(&m).unwrap()),
                    Err(e) => (e.status_code(), e.to_json()),
                }
            }
            ("DELETE", path) if path.starts_with("/mailboxes/") && path.ends_with("/delete") => {
                let Some(t) = token else { return (401, r#"{"error":"unauthorized"}"#.into()); };
                let Some(u) = self.user_service.authenticate_token(t) else { return (401, r#"{"error":"unauthorized"}"#.into()); };
                let id = path.strip_prefix("/mailboxes/").unwrap().strip_suffix("/delete").unwrap();
                match self.mailbox_service.delete_for_owner(&u.id, id) {
                    Ok(_) => (200, r#"{"status":"success","message":"Mailbox deleted"}"#.into()),
                    Err(e) => (e.status_code(), e.to_json()),
                }
            }
            ("GET", "/apps") => match handle_get_apps(&self.settings) {
                Ok(r) => (200, serde_json::to_string(&r).unwrap()),
                Err(e) => (e.status_code(), e.to_json()),
            },
            _ => (404, r#"{"error":"not_found","message":"Unknown endpoint"}"#.into()),
        }
    }
}
```

Update `crates/deltachat/src/lib.rs` to export `router::DeltaChatRouter`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test -p deltachat --test router_tests`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add crates/deltachat/src/router.rs crates/deltachat/src/lib.rs crates/deltachat/tests/router_tests.rs
git commit -m "feat(deltachat): implement DeltaChatRouter with complete route dispatching"
```

---

### Task 12: Server Singleton & Stalwart HTTP Layer Wiring

**Files:**
- Modify: `crates/common/src/lib.rs` or `crates/http/src/lib.rs`
- Modify: `crates/http/Cargo.toml`
- Modify: `crates/http/src/api/mod.rs`
- Modify: `crates/http/src/request.rs`

**Interfaces:**
- Attaches `deltachat: Arc<DeltaChatRouter>` to `Server`.
- Routes `/api/v1/*`, `/api/deltachat/*`, `/api/signup`, `/api/auth/*`, and `/apps/xdcstore/*`.

- [ ] **Step 1: Add `deltachat` dependency to `crates/http/Cargo.toml`**

Add `deltachat = { path = "../deltachat" }` to `[dependencies]`.

- [ ] **Step 2: Add `deltachat: Arc<DeltaChatRouter>` to `Server` struct**

In `crates/http/src/lib.rs`:
```rust
pub deltachat: std::sync::Arc<deltachat::router::DeltaChatRouter>,
```
Initialize in `Server::new` with `DeltaChatRouter::new(DeltaChatSettings::default())`.

- [ ] **Step 3: Route API requests in `crates/http/src/api/mod.rs`**

Under `handle_api_request`:
```rust
"v1" | "deltachat" | "signup" | "auth" | "mailboxes" => {
    let auth_header = req.headers().get(hyper::header::AUTHORIZATION).and_then(|h| h.to_str().ok());
    if auth_header.is_none() {
        self.is_http_anonymous_request_allowed(session.remote_ip).await?;
    }
    let body_bytes = body.as_deref();
    let (status, resp_body) = self.deltachat.dispatch(req.method().as_str(), req.uri().path(), auth_header, body_bytes).await;

    return Ok(HttpResponse::new(StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR))
        .with_header(hyper::header::CONTENT_TYPE, "application/json")
        .with_no_cache()
        .with_text_body(resp_body));
}
```

- [ ] **Step 4: Route static WebXDC package downloads in `crates/http/src/request.rs`**

Under `parse_http_request`:
```rust
"apps" if path.starts_with("/apps/xdcstore/") => {
    self.is_http_anonymous_request_allowed(session.remote_ip).await?;
    // Return embedded static asset stream
}
```

- [ ] **Step 5: Verify workspace build**

Run: `cargo check -p http`  
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add crates/http/Cargo.toml crates/http/src/ crates/common/src/
git commit -m "feat(http): wire persistent DeltaChatRouter singleton into Stalwart API pipeline"
```

---

### Task 13: End-to-End Pipeline Verification

**Files:**
- Test: `crates/deltachat/tests/e2e_tests.rs`

- [ ] **Step 1: Write comprehensive end-to-end integration test**

```rust
use deltachat::config::DeltaChatSettings;
use deltachat::router::DeltaChatRouter;

#[tokio::test]
async fn test_e2e_full_feature_parity() {
    let router = DeltaChatRouter::new(DeltaChatSettings::default());

    // 1. Config & Health
    let (code, body) = router.dispatch("GET", "/api/v1/config", None, None).await;
    assert_eq!(code, 200);
    assert!(body.contains("localhost"));

    // 2. Altcha Challenge
    let (code, body) = router.dispatch("GET", "/api/v1/altcha/challenge", None, None).await;
    assert_eq!(code, 200);
    assert!(body.contains("SHA-256"));

    // 3. Instant Account
    let (code, body) = router.dispatch("POST", "/api/v1/accounts/instant", None, Some(b"{}")).await;
    assert_eq!(code, 201);
    assert!(body.contains("dclogin:dc_"));

    // 4. Product Registration
    let reg_body = serde_json::to_vec(&serde_json::json!({
        "username": "alice", "email": "alice@example.com", "password": "Password123!"
    })).unwrap();
    let (code, body) = router.dispatch("POST", "/api/v1/auth/register", None, Some(&reg_body)).await;
    assert_eq!(code, 201);
    let val: serde_json::Value = serde_json::from_str(&body).unwrap();
    let token = val["token"].as_str().unwrap();

    // 5. Authenticated Mailbox Creation
    let mbx_body = serde_json::to_vec(&serde_json::json!({
        "username": "support", "domain": "localhost", "password": "SupportPassword123!"
    })).unwrap();
    let auth_header = format!("Bearer {token}");
    let (code, body) = router.dispatch("POST", "/api/v1/mailboxes", Some(&auth_header), Some(&mbx_body)).await;
    assert_eq!(code, 201);

    // 6. List Mailboxes
    let (code, body) = router.dispatch("GET", "/api/v1/mailboxes", Some(&auth_header), None).await;
    assert_eq!(code, 200);
    assert!(body.contains("support@localhost"));

    // 7. WebXDC Catalog
    let (code, body) = router.dispatch("GET", "/api/v1/apps", None, None).await;
    assert_eq!(code, 200);
    assert!(body.contains("chat.delta.webxdc.chess"));
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `cargo test -p deltachat --test e2e_tests`  
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add crates/deltachat/tests/e2e_tests.rs
git commit -m "test(deltachat): add end-to-end integration test verifying full feature parity"
```
