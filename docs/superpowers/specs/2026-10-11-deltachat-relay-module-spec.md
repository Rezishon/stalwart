# Specification: Unified DeltaChat & Relay Module for Stalwart
**Document ID:** `SPEC-2026-10-11-DELTACHAT-RELAY-UNIFIED`  
**Status:** Reviewed & Approved (Multi-Agent Audited)  
**Target:** Stalwart Mail Server (`crates/deltachat` & `crates/http`)  
**Design Principles:** Clean Code, DRY, KISS, Zero-Overhead, Offline Human Readable  

---

## 1. Executive Summary & Objective

This specification consolidates **all capabilities** of both the DeltaChat Onboarding API (`CHATCHI_BACKEND_API_SPEC.md`) and the Relay Middleware Backend (`signup-relay/backend`) into a single, clean, high-performance Rust crate: `crates/deltachat`.

By implementing these features natively inside Stalwart, we eliminate the need for an external Django application, Python runtime, or external database (SQLite/PostgreSQL). The entire onboarding, authentication, and mailbox management lifecycle runs single-binary with zero VPS overhead.

---

## 2. Architectural Principles & Module Boundaries

1. **Pluggable & Disablable**:
   - **Compile-time:** Crate feature `deltachat` in workspace `Cargo.toml`.
   - **Runtime:** `DeltaChatSettings.enabled: bool`. When disabled, all routes immediately return `404 Not Found` with zero resource overhead.
2. **Stateful Singleton Lifetime**:
   - `DeltaChatState` is instantiated once during server bootstrap and stored as `Arc<DeltaChatState>` on `Server`. It maintains persistent Altcha HMAC keys, the anti-replay cache, and active user session tokens.
3. **Clean Layering & DRY**:
   - **Shared Provisioning Core:** A single `MailboxService` powers both anonymous public self-signup (`/accounts/instant`, `/accounts/custom`, `/signup`) and authenticated user mailbox provisioning (`/mailboxes`), writing directly to Stalwart's directory registry.
   - **Unified Auth:** Lightweight Token Authentication for product users who manage multiple mailboxes, leveraging Stalwart's asynchronous Argon2id password verification.
   - **Built-in Bot Protection:** Cryptographic Altcha PoW engine with HMAC challenge binding and bounded `CacheWithTtl` replay protection.
   - **Embedded WebXDC Store:** Catalog metadata and static `.xdc` asset streaming.
4. **KISS & Offline Human Readability**:
   - Concise Rust files organized by domain rather than excessive micro-crates.
   - Plain `assert!` unit tests with zero complex test harness requirements.

---

## 3. Directory Layout (`crates/deltachat`)

```text
crates/deltachat/
├── Cargo.toml
└── src/
    ├── lib.rs                  # Module entrypoint & public exports
    ├── config.rs               # DeltaChatSettings (toggle, domains, endpoints, limits)
    ├── error.rs                # DeltaChatError mapping to HTTP status & safe JSON
    ├── models/
    │   ├── mod.rs
    │   ├── system.rs           # Health, Config, Domain models
    │   ├── auth.rs             # Product User, Login, Token models (Redacted Debug)
    │   ├── accounts.rs         # Mailbox & Account DTOs (Redacted Debug)
    │   └── apps.rs             # WebXDC app catalog models
    ├── security/
    │   ├── mod.rs
    │   ├── altcha.rs           # Altcha PoW challenge generator & TTL replay cache
    │   ├── token.rs            # Bearer token generator, validator & session cache
    │   └── dclogin.rs          # DeltaChat dclogin: URI builder (form_urlencoded)
    ├── services/
    │   ├── mod.rs
    │   ├── user_service.rs     # Product owner registration & authentication
    │   └── mailbox_service.rs  # Mailbox provisioning, password reset, suspend, delete
    ├── handlers/
    │   ├── mod.rs
    │   ├── public.rs           # /health, /config, /domains, /username/:val, /altcha
    │   ├── auth.rs             # /auth/register, /auth/login, /auth/logout, /me
    │   ├── mailboxes.rs        # /accounts/*, /signup, /mailboxes/*
    │   └── apps.rs             # /apps & /apps/xdcstore/*
    ├── router.rs               # Async HTTP dispatcher with rate limiting & 64KB body caps
    └── tests/
        ├── altcha_tests.rs
        ├── auth_tests.rs
        ├── mailbox_tests.rs
        └── e2e_tests.rs
```

---

## 4. API Specification & Feature Parity

Endpoints are served under `/api/v1/*` (with `/api/*` compatibility aliases) and `/apps/xdcstore/*`.

### 4.1. Public Discovery & Verification

#### `GET /api/v1/health`
- **Auth:** Public
- **Response `200 OK`:**
  ```json
  { "status": "healthy", "version": "1.0.0-chatchi", "uptime_seconds": 348120 }
  ```

#### `GET /api/v1/config`
- **Auth:** Public
- **Response `200 OK`:**
  ```json
  {
    "brand": "R.I.S.E / DeltaChat",
    "domain": "chatchi.org",
    "allowed_domains": ["chatchi.org", "delta.chatchi.org"],
    "registration_open": true,
    "instant_accounts_enabled": true,
    "custom_accounts_enabled": true,
    "endpoints": {
      "imap": { "host": "mail.chatchi.org", "port": 993, "security": "ssl" },
      "smtp": { "host": "mail.chatchi.org", "port": 465, "security": "ssl" }
    },
    "altcha": { "required": true, "max_number": 500000 }
  }
  ```

#### `GET /api/v1/domains`
- **Auth:** Public
- **Response `200 OK`:**
  ```json
  [
    { "name": "chatchi.org", "domain": "chatchi.org", "is_default": true },
    { "name": "delta.chatchi.org", "domain": "delta.chatchi.org", "is_default": false }
  ]
  ```

#### `GET /api/v1/username/:value`
- **Auth:** Public
- **Response `200 OK`:**
  ```json
  { "username": "alice", "available": true }
  ```

#### `GET /api/v1/altcha/challenge`
- **Auth:** Public
- **Response `200 OK`:**
  ```json
  {
    "algorithm": "SHA-256",
    "challenge": "e3b0c442...",
    "salt": "1760130000:7a8b...",
    "signature": "8f4a3b2c...",
    "max_number": 500000
  }
  ```
- **Security:** HMAC strictly binds `salt` and `challenge`. Replay cache uses `CacheWithTtl` (120s expiry).

---

### 4.2. Onboarding & Mailbox Provisioning (Public Self-Registration)

#### `POST /api/v1/accounts/instant`
- **Auth:** Public | **Headers:** `Idempotency-Key: <UUID>`
- **Request Body:** `{ "altcha_payload": "..." }`
- **Response `201 Created`:**
  ```json
  {
    "account_id": "acc_01hxyz1234",
    "email": "dc_a8f9b2c3d4e5@chatchi.org",
    "password": "GeneratedSecretPassword24Chars!",
    "dclogin_link": "dclogin:dc_a8f9b2c3d4e5@chatchi.org/?p=...&ih=mail.chatchi.org&ip=993...",
    "account_type": "instant",
    "quota_mb": 50
  }
  ```

#### `POST /api/v1/accounts/custom` (and legacy `/api/signup`)
- **Auth:** Public | **Headers:** `Idempotency-Key: <UUID>`
- **Request Body:**
  ```json
  {
    "username": "rezishon",
    "domain": "chatchi.org",
    "password": "MySecurePassword123#",
    "altcha_payload": "..."
  }
  ```
- **Response `201 Created`:**
  ```json
  {
    "account_id": "acc_01hxyz9876",
    "email": "rezishon@chatchi.org",
    "dclogin_link": "dclogin:rezishon@chatchi.org/?p=...&ih=mail.chatchi.org&ip=993...",
    "account_type": "custom"
  }
  ```

---

### 4.3. Product Identity & User Authentication

Allows users to create a product account to manage one or more mailboxes.

#### `POST /api/v1/auth/register`
- **Auth:** Public
- **Request Body:**
  ```json
  { "username": "erfan", "email": "erfan@example.com", "password": "SecurePassword123!" }
  ```
- **Response `201 Created`:**
  ```json
  {
    "token": "dcat_a1b2c3d4e5f60718293a4b5c6d7e8f90",
    "user": { "id": "usr_01", "username": "erfan", "email": "erfan@example.com" }
  }
  ```

#### `POST /api/v1/auth/login`
- **Auth:** Public
- **Request Body:** `{ "username": "erfan", "password": "SecurePassword123!" }`
- **Response `200 OK`:** Same token payload as register.

#### `POST /api/v1/auth/logout`
- **Auth:** `Authorization: Bearer <token>`
- **Response `204 No Content`**

#### `GET /api/v1/me`
- **Auth:** `Authorization: Bearer <token>`
- **Response `200 OK`:** `{ "id": "usr_01", "username": "erfan", "email": "erfan@example.com" }`

---

### 4.4. Mailbox Lifecycle Management (Authenticated)

Product users can list, create, change passwords for, suspend, resume, and delete their mailboxes.

#### `GET /api/v1/mailboxes`
- **Auth:** `Authorization: Bearer <token>`
- **Response `200 OK`:**
  ```json
  [
    {
      "id": "mbx_01",
      "email": "sales@example.com",
      "status": "active",
      "imap_host": "mail.chatchi.org",
      "imap_port": 993,
      "smtp_host": "mail.chatchi.org",
      "smtp_port": 465,
      "security": "SSL"
    }
  ]
  ```

#### `POST /api/v1/mailboxes`
- **Auth:** `Authorization: Bearer <token>` | **Headers:** `Idempotency-Key: <UUID>`
- **Request Body:**
  ```json
  { "username": "sales", "domain": "example.com", "password": "MailboxPassword123!" }
  ```
- **Response `201 Created`** (or `200 OK` on replay).

#### `GET /api/v1/mailboxes/:id`
- **Auth:** `Authorization: Bearer <token>`
- **Response `200 OK`:** Single mailbox status and settings.

#### `POST /api/v1/mailboxes/:id/password`
- **Auth:** `Authorization: Bearer <token>`
- **Request Body:** `{ "password": "NewSecurePassword456!" }`
- **Response `200 OK`:** `{ "status": "success", "message": "Password updated" }`

#### `POST /api/v1/mailboxes/:id/suspend`
- **Auth:** `Authorization: Bearer <token>`
- **Response `200 OK`:** `{ "id": "mbx_01", "status": "suspended" }`

#### `POST /api/v1/mailboxes/:id/resume`
- **Auth:** `Authorization: Bearer <token>`
- **Response `200 OK`:** `{ "id": "mbx_01", "status": "active" }`

#### `DELETE /api/v1/mailboxes/:id/delete`
- **Auth:** `Authorization: Bearer <token>`
- **Response `200 OK`:** `{ "status": "success", "message": "Mailbox deleted" }`

---

### 4.5. WebXDC App Store & Static Streaming

#### `GET /api/v1/apps`
- **Auth:** Public
- **Response `200 OK`:** JSON catalog of WebXDC apps.

#### `GET /apps/xdcstore/*`
- **Auth:** Public
- **Response `200 OK`:** Streams `.xdc` packages and app icons with immutable cache headers and `Content-Disposition`.

---

## 5. Security & Invariants

1. **Password Security**:
   - CSPRNG (`store::rand::random`) for all secret generation.
   - Asynchronous Argon2id password hashing via `directory::core::secret::hash_secret` and verification via `directory::core::secret::verify_secret_hash`.
   - `#[derive(Debug)]` implementations redact `password` and `dclogin_link`.
2. **Access Control & Ownership Isolation**:
   - Authenticated mailbox endpoints strictly verify that the requested `mailbox_id` is owned by the token's authenticated user. Mismatches return `404 Not Found` (no ownership leakage).
3. **Altcha Bot Protection**:
   - Signature binds `salt` and `challenge`.
   - Constant-time verification prevents timing side-channels.
   - Bounded `CacheWithTtl` replay cache (120s TTL) prevents replay floods.
4. **Rate Limiting & Payload Caps**:
   - Anonymous requests pass through Stalwart's IP rate limiter (`is_http_anonymous_request_allowed`). Authenticated requests bypass anonymous IP throttling.
   - Request bodies capped at 64 KB.

---

## 6. Comprehensive 6-Phase Roadmap

```
+-------------------------------------------------------------------------------+
| PHASE 1: Core Foundation & Configuration                                      |
| - Create crates/deltachat crate and workspace registration                   |
| - DeltaChatSettings with enable/disable toggle                                |
| - DeltaChatError and safe JSON error mapping                                  |
| - System Health & Config endpoints (/health, /config, /domains)               |
+---------------------------------------+---------------------------------------+
                                        |
                                        v
+-------------------------------------------------------------------------------+
| PHASE 2: Bot Protection & Availability Checks                                 |
| - Altcha PoW engine with challenge-bound HMAC and CacheWithTtl replay cache   |
| - GET /altcha/challenge endpoint                                              |
| - GET /username/:value availability check                                     |
+---------------------------------------+---------------------------------------+
                                        |
                                        v
+-------------------------------------------------------------------------------+
| PHASE 3: Public Account Onboarding & dclogin                                  |
| - DeltaChat dclogin: URI generator via form_urlencoded                        |
| - CSPRNG secure password generator                                            |
| - POST /accounts/instant and POST /accounts/custom (with /signup alias)       |
| - Idempotency-Key support with replay cache                                   |
+---------------------------------------+---------------------------------------+
                                        |
                                        v
+-------------------------------------------------------------------------------+
| PHASE 4: Product Identity & Token Auth                                        |
| - Product user model with async Argon2id password hashing                     |
| - Token engine with CacheWithTtl session management & .remove() revocation   |
| - POST /auth/register, POST /auth/login, POST /auth/logout, GET /me            |
+---------------------------------------+---------------------------------------+
                                        |
                                        v
+-------------------------------------------------------------------------------+
| PHASE 5: Mailbox Lifecycle Management                                         |
| - Ownership-aware MailboxService                                              |
| - GET /mailboxes, POST /mailboxes, GET /mailboxes/:id                         |
| - POST /mailboxes/:id/password, suspend, resume, delete                       |
+---------------------------------------+---------------------------------------+
                                        |
                                        v
+-------------------------------------------------------------------------------+
| PHASE 6: WebXDC Store & Stalwart HTTP Integration                             |
| - GET /apps catalog & /apps/xdcstore/* static asset streaming                 |
| - Server-level singleton DeltaChatRouter state                                |
| - Wiring into crates/http/src/api/mod.rs and request.rs                       |
| - End-to-End integration test suite                                           |
+---------------------------------------+---------------------------------------+
```
