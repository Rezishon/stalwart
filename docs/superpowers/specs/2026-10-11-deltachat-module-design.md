# Architectural Specification: DeltaChat Module & Admin Settings for Stalwart

**Document ID:** `SPEC-2026-10-11-DELTACHAT-MODULE-DESIGN`  
**Status:** Approved  
**Target:** Stalwart Mail Server (`crates/deltachat`, `crates/http`, `crates/registry`, `crates/jmap`, `resources/schema`)  
**Design Principles:** Clean Code, DRY, KISS, Zero-Overhead, Offline Human Readable  

---

## 1. Executive Summary & Objective

This specification defines the complete architecture for the dedicated **DeltaChat Module** (`crates/deltachat`) inside Stalwart Mail Server. It delivers:
1. **Admin Dashboard Integration:** First-class entry in Admin WebUI Settings menu (`Layout 1`) with four sub-menus:
   - **General:** Master `enabled` toggle, `registration_open`, `instant_accounts_enabled`, `custom_accounts_enabled`.
   - **Domains:** Primary default domain and allowed domains list for custom mailbox provisioning.
   - **Endpoints:** IMAP and SMTP connection parameters (host, port, security mode) for discovery and `dclogin:` URI creation.
   - **Bot Protection (Altcha):** Altcha PoW challenge parameters (`required`, `max_number`, `hmac_secret`).
2. **Schema & JMAP Persistence:** Full registry entity `ObjectType::DeltaChat = 117` singleton with JMAP get/set handlers and default bootstrapping.
3. **Core RESTful Endpoints:**
   - `POST /api/v1/accounts/instant` — Cryptographic instant mailbox generation + `dclogin:` link.
   - `POST /api/v1/accounts/custom` — Custom user mailbox provisioning with validation + `dclogin:` link.
   - `GET /api/v1/apps` — WebXDC App Store catalog.
   - `GET /api/v1/health` — System uptime and version health probe.
   - `GET /api/v1/config` — Public configuration discovery with connection metadata and Altcha parameters.
   - Static WebXDC assets delivery under `/apps/xdcstore/*`.
4. **Zero-Overhead Embedded Frontend:** Compile-time `.rodata` serving of the built React onboarding relay SPA (`../signup-relay/frontend/dist`), with SPA routing fallback to `index.html` and optional runtime filesystem override.

---

## 2. Directory Layout & Module Hierarchy

```text
crates/deltachat/
├── Cargo.toml
└── src/
    ├── lib.rs                  # Module entrypoint, public exports, and HTTP dispatch entry
    ├── config.rs               # DeltaChatSettings (enabled, domains, endpoints, altcha)
    ├── error.rs                # DeltaChatError mapping to HTTP status codes & safe JSON
    ├── models.rs               # Strongly-typed Serde DTOs (redacted Debug for secrets)
    ├── dclogin.rs              # DeltaChat setup URI generator (dclogin: URI spec via form_urlencoded)
    ├── altcha.rs               # Altcha PoW engine (HMAC-SHA256, constant-time, CacheWithTtl replay cache)
    ├── catalog.rs              # WebXDC app catalog store & static package streaming
    ├── handlers/
    │   ├── mod.rs
    │   ├── system.rs           # GET /api/v1/health & GET /api/v1/config
    │   ├── accounts.rs         # POST /api/v1/accounts/instant & POST /api/v1/accounts/custom
    │   └── apps.rs             # GET /api/v1/apps & GET /apps/xdcstore/*
    └── assets/
        ├── mod.rs
        └── web.rs              # Zero-overhead embedded static frontend assets (index.html, js, css)
```

---

## 3. Schema & Admin Dashboard Integration (`resources/schema/schema.json`)

### 3.1. Settings Menu Layout (`layouts[1]`)
Add container under `layouts[1].items`:
```json
{
  "container": {
    "name": "DeltaChat",
    "icon": "message-square",
    "items": [
      { "name": "General", "type": "link", "viewName": "x:DeltaChat/DeltaChatGeneral" },
      { "name": "Domains", "type": "link", "viewName": "x:DeltaChat/DeltaChatDomains" },
      { "name": "Endpoints", "type": "link", "viewName": "x:DeltaChat/DeltaChatEndpoints" },
      { "name": "Bot Protection", "type": "link", "viewName": "x:DeltaChat/DeltaChatAltcha" }
    ]
  }
}
```

### 3.2. Object Definitions (`objects`)
- `"x:DeltaChat"`:
  ```json
  {
    "type": "singleton",
    "description": "Configures DeltaChat core integration, endpoints, and account provisioning.",
    "permissionPrefix": "sysSystemSettings"
  }
  ```
- Submenu View Links:
  - `"x:DeltaChat/DeltaChatGeneral"`: `{ "type": "view", "objectName": "x:DeltaChat" }`
  - `"x:DeltaChat/DeltaChatDomains"`: `{ "type": "view", "objectName": "x:DeltaChat" }`
  - `"x:DeltaChat/DeltaChatEndpoints"`: `{ "type": "view", "objectName": "x:DeltaChat" }`
  - `"x:DeltaChat/DeltaChatAltcha"`: `{ "type": "view", "objectName": "x:DeltaChat" }`

### 3.3. Schema Definition (`schemas`)
- `"x:DeltaChat"`:
  ```json
  {
    "type": "single",
    "schemaName": "x:DeltaChat"
  }
  ```

### 3.4. Form Definitions (`forms`)
- `"x:DeltaChat/DeltaChatGeneral"`:
  - Fields: `enabled` (boolean), `registrationOpen` (boolean), `instantAccountsEnabled` (boolean), `customAccountsEnabled` (boolean), `frontendPath` (string, optional override).
- `"x:DeltaChat/DeltaChatDomains"`:
  - Fields: `domain` (string, primary), `allowedDomains` (list of strings).
- `"x:DeltaChat/DeltaChatEndpoints"`:
  - Section IMAP: `imapHost` (string), `imapPort` (number, default 993), `imapSecurity` (enum: ssl, starttls).
  - Section SMTP: `smtpHost` (string), `smtpPort` (number, default 465), `smtpSecurity` (enum: ssl, starttls).
- `"x:DeltaChat/DeltaChatAltcha"`:
  - Fields: `altchaRequired` (boolean), `altchaMaxNumber` (number, default 100000), `altchaHmacSecret` (secret string).

### 3.5. Packaging
- Compile: `gzip -k9 -c schema.json > resources/schema/schema.json.gz`
- Checksum: `sha256sum resources/schema/schema.json.gz | awk '{print $1}' > resources/schema/schema.json.sha256`

---

## 4. JMAP & Registry Persistence Layer

### 4.1. Registry Types (`crates/registry`)
1. In `crates/registry/src/schema/properties.rs`:
   - `ObjectInner::DeltaChat(DeltaChat)`
   - `ObjectType::DeltaChat = 117`
2. In `crates/registry/src/schema/properties_impl.rs`:
   - Add `b"DeltaChat" => ObjectType::DeltaChat` in `tiny_map!`.
   - Add `ObjectType::DeltaChat => "DeltaChat"`.
   - Add `117 => Some(ObjectType::DeltaChat)` in `from_id`.
   - Increment `const COUNT: usize = 118;`.
   - Implement `Pickle`, `Deserialize`, `From/Into` forwarders for `ObjectInner::DeltaChat`.
3. In `crates/registry/src/schema/structs.rs` & `structs_impl.rs`:
   - Implement `pub struct DeltaChat` with all configurable fields.
   - Implement `ObjectImpl` with `FLAGS = OBJ_SINGLETON`, `VERSION = 0`, `OBJECT = ObjectType::DeltaChat`.
   - Implement `Pickle`, `Default`, `IntoValue`, and `RegistryJsonPropertyPatch`.

### 4.2. JMAP Get / Set (`crates/jmap`)
- In `crates/jmap/src/registry/get.rs`: Add `| ObjectType::DeltaChat` to supported singleton objects.
- In `crates/jmap/src/registry/set.rs`: Add `| ObjectType::DeltaChat` to supported singleton objects.

### 4.3. Default Bootstrap (`crates/common/src/manager/defaults.rs`)
- In `insert_safe_defaults(bp)`:
  ```rust
  if bp.registry.count_object(ObjectType::DeltaChat).await? == 0 {
      bp.registry.write(RegistryWrite::insert(&DeltaChat::default().into())).await?;
  }
  ```

---

## 5. Endpoints Specification

### 5.1. Instant Account Creation
- **Route:** `POST /api/v1/accounts/instant`
- **Request Body:** `{ "altcha_payload": string (optional) }`
- **Response `201 Created`:**
  ```json
  {
    "account_id": "acc_01hxyz...",
    "email": "dc_abc123@chatchi.org",
    "password": "Generated24CharPassword",
    "dclogin_link": "dclogin:dc_abc123@chatchi.org/?p=...&v=1&ih=mail.chatchi.org&ip=993&is=ssl&sh=mail.chatchi.org&sp=465&ss=ssl&ic=3",
    "account_type": "instant",
    "expires_at": "2026-11-10T23:59:59Z"
  }
  ```

### 5.2. Custom Mailbox Creation
- **Route:** `POST /api/v1/accounts/custom`
- **Request Body:**
  ```json
  {
    "username": "rezishon",
    "password": "AutoGeneratedOrCustomPassword",
    "altcha_payload": "base64_altcha_solution"
  }
  ```
- **Response `201 Created`:**
  ```json
  {
    "account_id": "acc_01hxyz...",
    "email": "rezishon@chatchi.org",
    "dclogin_link": "dclogin:rezishon@chatchi.org/?p=...&v=1&ih=mail.chatchi.org&ip=993&is=ssl&sh=mail.chatchi.org&sp=465&ss=ssl&ic=3",
    "account_type": "custom"
  }
  ```

### 5.3. WebXDC App Store Catalog
- **Route:** `GET /api/v1/apps`
- **Response `200 OK`:**
  ```json
  {
    "version": "1.0",
    "apps": [
      {
        "app_id": "chat.delta.webxdc.chess",
        "name": "Chess",
        "version": "1.4.2",
        "description": "Play chess with contacts in DeltaChat",
        "size": 420000,
        "icon_url": "/apps/xdcstore/icons/chess.png",
        "download_url": "/apps/xdcstore/packages/chess.xdc"
      }
    ]
  }
  ```
- **Static Assets Delivery (`GET /apps/xdcstore/*`):** Streams package archives and icons directly from memory.

### 5.4. System Health Check
- **Route:** `GET /api/v1/health`
- **Response `200 OK`:**
  ```json
  {
    "status": "healthy",
    "version": "1.0.0-chatchi",
    "uptime_seconds": 3600
  }
  ```

### 5.5. Config Discovery Alignment
- **Route:** `GET /api/v1/config`
- **Response `200 OK`:**
  ```json
  {
    "domain": "chatchi.org",
    "registration_open": true,
    "instant_accounts_enabled": true,
    "endpoints": {
      "imap": { "host": "mail.chatchi.org", "port": 993, "security": "ssl" },
      "smtp": { "host": "mail.chatchi.org", "port": 465, "security": "ssl" }
    },
    "altcha": {
      "required": true,
      "max_number": 100000
    }
  }
  ```

---

## 6. HTTP Routing & Zero-Overhead Frontend Integration

In `crates/http/src/request.rs`:
- Route matching for `/api/v1/accounts/*`, `/api/v1/apps`, `/api/v1/health`, `/api/v1/config`, and `/apps/xdcstore/*`.
- Route matching for root frontend paths (`/`, `/apps`, `/docs`, `/share`) serving compile-time embedded `.rodata` assets with `Cache-Control: public, max-age=31536000, immutable` for static files, and `no-cache` HTML fallback.
- Dynamic toggle guard: When `DeltaChat` is disabled in settings, all DeltaChat API and frontend routes return `404 Not Found` with zero memory allocation.

---

## 7. Quality, Verification & Review Gates

- **Unit Tests:**
  - `dclogin` URI generation and encoding tests.
  - Altcha challenge verification, HMAC constant-time checking, and replay attack prevention.
  - Serialization/deserialization tests for `DeltaChat` config struct.
- **Cargo Checks:**
  - `cargo check -p deltachat`
  - `cargo check -p stalwart`
- **Specialized Multi-Agent Verification:**
  - `schema-reviewer`: Audits schema.json forms, layout, JMAP get/set, and permissions.
  - `security-reviewer`: Audits Altcha crypto, password generation, Argon2id hashing, and input validation.
  - `verifier`: Executes `cargo test` and `cargo check`.
