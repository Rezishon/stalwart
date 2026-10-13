# Specification: DeltaChat Core Module for Stalwart Mail Server
**Document ID:** `SPEC-2026-10-11-DELTACHAT-MODULE-API`  
**Status:** Reviewed & Approved (Security & Rust Audited)  
**Target:** Stalwart Mail Server (`crates/deltachat`) & Relay-Page Frontend (`../signup-relay`)  
**Design Principles:** Clean Code, DRY, KISS, Zero-Overhead, Offline Human Readable  

---

## 1. Executive Summary & Objective

This specification defines the dedicated **DeltaChat Module** (`crates/deltachat`) for Stalwart mail server. 
It fulfills all RESTful API requirements expected by the DeltaChat onboarding frontend (`../signup-relay`), enables high-performance instant and custom account provisioning, cryptographic bot protection (Altcha PoW), and the WebXDC app catalog—packaged as an installable, disablable, clean, and self-contained Rust module.

The legacy `/api/v1/blog` endpoint is **explicitly omitted** per architecture requirements.

---

## 2. Core Architectural Principles

1. **Pluggable & Disablable (Feature & Runtime Toggles)**:
   - **Compile-time**: Crate feature `deltachat` in workspace `Cargo.toml`. Can be omitted if building minimal variants.
   - **Runtime**: Dynamic configuration flag `DeltaChatSettings.enabled: bool`. When `false`, all endpoints return `404 Not Found` with zero resource consumption.
2. **KISS & DRY**:
   - Reuses Stalwart's existing store, auth hashing, HTTP engine, and IP rate limiting.
   - Uses existing workspace utilities (`utils::cache::CacheWithTtl` for replay protection, `form_urlencoded` for URI generation, CSPRNG for password generation).
3. **Offline Human Readability**:
   - Structured for offline developer maintainability: single-purpose modules, clear type definitions, explicit documentation, and comprehensive runnable unit tests with standard `assert!` checks.
4. **Zero VPS Overhead**:
   - Operates in-memory and inside the single monolithic binary. Zero external runtime dependencies.

---

## 3. Directory Layout (`crates/deltachat`)

```text
crates/deltachat/
├── Cargo.toml
└── src/
    ├── lib.rs                  # Module entrypoint & public exports
    ├── config.rs               # DeltaChatSettings (enabled, domains, limits, endpoints)
    ├── error.rs                # DeltaChatError enum mapping to HTTP status/safe JSON
    ├── models.rs               # Request/Response DTOs (Serde serializable, redacted Debug)
    ├── dclogin.rs              # DeltaChat setup URI generator (dclogin: URI spec via form_urlencoded)
    ├── altcha.rs               # Altcha PoW engine, HMAC challenge binding, CacheWithTtl replay cache
    ├── catalog.rs              # WebXDC app catalog store & static package streaming
    ├── handlers/
    │   ├── mod.rs
    │   ├── system.rs           # GET /api/v1/health & GET /api/v1/config
    │   ├── altcha.rs           # GET /api/v1/altcha/challenge
    │   ├── accounts.rs         # POST /api/v1/accounts/instant & /accounts/custom
    │   └── apps.rs             # GET /api/v1/apps & GET /apps/xdcstore/*
    └── tests/
        ├── dclogin_tests.rs    # URI formatting and parameter tests
        ├── altcha_tests.rs     # Cryptographic challenge, HMAC binding, and replay tests
        └── handler_tests.rs    # Endpoints and validation tests
```

---

## 4. API Endpoints Specification

Base Path: `/api/v1` (and `/apps/xdcstore/*` for WebXDC static assets).

### 4.1. System Health Check
- **Route:** `GET /api/v1/health`
- **Authentication:** Public / Anonymous
- **Response `200 OK`:**
  ```json
  {
    "status": "healthy",
    "version": "1.0.0-chatchi",
    "uptime_seconds": 348120
  }
  ```

### 4.2. Public Configuration Discovery
- **Route:** `GET /api/v1/config`
- **Authentication:** Public / Anonymous
- **Description:** Supplies client configuration, server domains, mail server connection parameters, and Altcha parameters.
- **Response `200 OK`:**
  ```json
  {
    "domain": "chatchi.org",
    "allowed_domains": ["chatchi.org", "delta.chatchi.org"],
    "registration_open": true,
    "instant_accounts_enabled": true,
    "custom_accounts_enabled": true,
    "endpoints": {
      "imap": {
        "host": "mail.chatchi.org",
        "port": 993,
        "security": "ssl"
      },
      "smtp": {
        "host": "mail.chatchi.org",
        "port": 465,
        "security": "ssl"
      }
    },
    "altcha": {
      "required": true,
      "max_number": 500000
    }
  }
  ```

### 4.3. Bot Protection: Altcha Proof-of-Work Challenge
- **Route:** `GET /api/v1/altcha/challenge`
- **Authentication:** Public / Anonymous
- **Response `200 OK`:**
  ```json
  {
    "algorithm": "SHA-256",
    "challenge": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "salt": "1760130000:7a8b9c0d1e2f3a4b",
    "signature": "8f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a",
    "max_number": 500000
  }
  ```
- **Security Invariants:**
  1. `salt` format: `<unix_timestamp>:<random_hex_16>`.
  2. Timestamp window: Valid if `|now - timestamp| <= 120s`.
  3. Signature: `HMAC-SHA256(server_secret, salt + ":" + challenge)`. Challenge and salt are strictly bound together in the signature to prevent O(1) PoW substitution attacks.
  4. Constant-Time Verification: Signature verified via `mac.verify_slice()` to prevent timing side-channel attacks.
  5. Challenge: `SHA-256(salt + solution_number)`.
  6. Replay Protection: Verified challenges are recorded in `CacheWithTtl` with 120-second TTL and bounded capacity. Replayed challenges are rejected immediately.

### 4.4. Instant DeltaChat Account Provisioning
- **Route:** `POST /api/v1/accounts/instant`
- **Headers:** `Idempotency-Key: <UUID>` (optional)
- **Request Body:**
  ```json
  {
    "altcha_payload": "optional-base64-payload"
  }
  ```
- **Processing:**
  1. Verify module is enabled and `instant_accounts_enabled == true`.
  2. Validate Altcha PoW if `altcha.required == true`.
  3. Generate secure random email (`dc_<12-hex-chars>@<primary_domain>`) and 24-character cryptographic password via CSPRNG.
  4. Create account entity in Stalwart store with Argon2id password hash.
  5. Generate standard DeltaChat `dclogin:` link.
- **Response `201 Created`:**
  ```json
  {
    "account_id": "acc_01hxyz1234567890",
    "email": "dc_a8f9b2c3d4e5@chatchi.org",
    "password": "GeneratedSecretPassword24Chars!",
    "dclogin_link": "dclogin:dc_a8f9b2c3d4e5@chatchi.org/?p=GeneratedSecretPassword24Chars%21&v=1&ih=mail.chatchi.org&ip=993&is=ssl&sh=mail.chatchi.org&sp=465&ss=ssl&ic=3",
    "account_type": "instant",
    "expires_at": "2026-11-10T23:59:59Z",
    "quota_mb": 50
  }
  ```

### 4.5. Custom Mailbox Account Provisioning
- **Route:** `POST /api/v1/accounts/custom`
- **Headers:** `Idempotency-Key: <UUID>` (optional)
- **Request Body:**
  ```json
  {
    "username": "rezishon",
    "domain": "chatchi.org",
    "password": "MySecurePassword123#",
    "altcha_payload": "eyJhbGdvcml0aG0iOiJTSEEtMjU2IiwiY2hhbGxlbmdlIjoiLi4uIiwibnVtYmVyIjoxMjM0NSwic2FsdCI6Ii4uLiIsInNpZ25hdHVyZSI6Ii4uLiJ9"
  }
  ```
- **Validations:**
  - Username: Length 3..=32, RFC 5322 dot-atom rules (no leading/trailing dots, no consecutive dots `..`).
  - Reserved Names: Must not match `admin`, `administrator`, `root`, `postmaster`, `hostmaster`, `abuse`, `support`, etc.
  - Domain: Must be in `allowed_domains` (case-insensitive match).
  - Password: Minimum 10 characters with mixed character classes.
  - Altcha verification if required.
  - Conflict check: If account exists in store, return `409 Conflict`.
- **Response `201 Created`:**
  ```json
  {
    "account_id": "acc_01hxyz9876543210",
    "email": "rezishon@chatchi.org",
    "dclogin_link": "dclogin:rezishon@chatchi.org/?p=MySecurePassword123%23&v=1&ih=mail.chatchi.org&ip=993&is=ssl&sh=mail.chatchi.org&sp=465&ss=ssl&ic=3",
    "account_type": "custom"
  }
  ```

### 4.6. WebXDC App Store & Static Asset Delivery
- **Route:** `GET /api/v1/apps`
- **Authentication:** Public / Anonymous
- **Response `200 OK`:** WebXDC Catalog JSON.
- **Static Asset Delivery (`/apps/xdcstore/*`):**
  - Streams embedded `.xdc` packages and icons with:
    ```http
    Content-Type: application/octet-stream
    Content-Disposition: attachment; filename="<name>.xdc"
    X-Content-Type-Options: nosniff
    Cache-Control: public, max-age=86400
    ```

---

## 5. Security & Invariant Analysis

1. **Cryptographic Protection**:
   - Altcha HMAC binds salt and challenge together.
   - Replay protection uses `CacheWithTtl` with 120s expiry and bounded capacity.
   - Constant-time signature verification prevents timing attacks.
2. **Account Passwords**:
   - CSPRNG (`store::rand::rng()`) used for all password and nonce generation.
   - Redacted `Debug` implementations to avoid password leaks in logs or panic backtraces.
   - Passwords hashed using Argon2id via Stalwart store.
3. **Rate Limiting & DoS Protection**:
   - Anonymous requests routed through Stalwart's IP rate limiter (`is_http_anonymous_request_allowed`).
   - Request body capped at 64 KB.
4. **Information Leakage**:
   - Internal errors return generic safe messages in HTTP JSON; detailed traces logged to internal spans only.

---

## 6. Comprehensive Module Roadmap

```
+-------------------------------------------------------------------------------+
| MILESTONE 1: Core Foundation & Configuration                                  |
| - Create crates/deltachat crate                                               |
| - Implement DeltaChatSettings model & runtime enable/disable toggle           |
| - Implement GET /api/v1/health & GET /api/v1/config                           |
| - Unit tests for router & config state                                        |
+---------------------------------------+---------------------------------------+
                                        |
                                        v
+-------------------------------------------------------------------------------+
| MILESTONE 2: Bot Protection (Altcha Engine with Replay Cache)                 |
| - Implement Altcha PoW challenge generation & HMAC challenge-binding          |
| - Implement CacheWithTtl Replay Cache (120s expiry, bounded size)             |
| - Constant-time signature verification                                        |
| - Implement GET /api/v1/altcha/challenge                                      |
+---------------------------------------+---------------------------------------+
                                        |
                                        v
+-------------------------------------------------------------------------------+
| MILESTONE 3: DeltaChat URI & Account Provisioning                             |
| - Implement dclogin URI generator with form_urlencoded                        |
| - CSPRNG secure password generation                                           |
| - Implement POST /api/v1/accounts/instant                                     |
| - Implement POST /api/v1/accounts/custom with RFC dot-atom & reserved checks  |
| - Real store integration & Argon2id hashing & 409 conflict handling           |
+---------------------------------------+---------------------------------------+
                                        |
                                        v
+-------------------------------------------------------------------------------+
| MILESTONE 4: WebXDC Store & Static Asset Serving                              |
| - Implement WebXDC catalog data provider                                      |
| - Implement GET /api/v1/apps                                                  |
| - Implement static streaming for /apps/xdcstore/*                             |
| - Unit tests for catalog serialization & headers                              |
+---------------------------------------+---------------------------------------+
                                        |
                                        v
+-------------------------------------------------------------------------------+
| MILESTONE 5: Stalwart HTTP Router & Lifecycle Integration                     |
| - Wire DeltaChat router into crates/http/src/request.rs and api/mod.rs        |
| - Wire runtime settings into crates/registry & crates/common bootstrap        |
| - End-to-end integration test of /api/v1 pipeline                             |
+---------------------------------------+---------------------------------------+
                                        |
                                        v
+-------------------------------------------------------------------------------+
| MILESTONE 6: Future Extensibility (Post-MVP)                                  |
| - WebUI Settings Schema form for DeltaChat configuration                      |
| - Chatmail compatibility protocol endpoints                                   |
| - Dynamic WebXDC catalog sync from remote upstream registry                   |
| - Ephemeral account auto-pruning task in crates/services                      |
+---------------------------------------+---------------------------------------+
```
