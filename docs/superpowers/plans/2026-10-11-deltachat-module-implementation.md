# DeltaChat Module & Admin Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the dedicated `DeltaChat` module (`crates/deltachat`) in Stalwart with full Admin Dashboard Settings menu integration, JMAP schema persistence, all 5 core REST endpoints, and zero-overhead compile-time frontend embedding.

**Architecture:** A self-contained workspace crate `crates/deltachat` containing configuration, domain models, cryptographic Altcha PoW verification with bounded TTL replay cache, DeltaChat `dclogin` URI generation via `form_urlencoded`, account provisioning wired into Stalwart store/registry with Argon2id hashing, WebXDC app catalog delivery, and compile-time embedded React SPA. It connects to Stalwart's schema layer (`crates/registry`, `crates/jmap`, `resources/schema`) and HTTP dispatcher (`crates/http`).

**Spec:** `docs/superpowers/specs/2026-10-11-deltachat-module-design.md`

---

## Roadmap Overview

```
[Phase 1: Crate Skeleton & Models]
       │
       ▼
[Phase 2: Registry Schema, JMAP & Defaults]
       │
       ▼
[Phase 3: WebUI Admin Settings (schema.json)]
       │
       ▼
[Phase 4: Altcha PoW & dclogin URI Engine]
       │
       ▼
[Phase 5: Core REST Endpoints & WebXDC Catalog]
       │
       ▼
[Phase 6: Embedded React SPA & HTTP Router Integration]
       │
       ▼
[Phase 7: End-to-End Verification & Multi-Agent Review]
```

---

### Phase 1: Crate Skeleton & Core Models

- [x] **Task 1.1: Create `crates/deltachat/Cargo.toml`**
  - Path: `crates/deltachat/Cargo.toml`
  - Dependencies: `common`, `types`, `utils`, `store`, `registry`, `directory`, `trc`, `hyper`, `serde`, `serde_json`, `sha2`, `hmac`, `hex`, `form_urlencoded`, `tokio`.
  - Add `"crates/deltachat"` to root workspace `Cargo.toml`.

- [x] **Task 1.2: Implement `crates/deltachat/src/config.rs`**
  - Defines `DeltaChatSettings`, `EndpointsConfig`, `MailEndpointConfig`, `AltchaSettings`.
  - Includes unit tests verifying default values and toggle behaviors.

- [x] **Task 1.3: Implement `crates/deltachat/src/models.rs` & `error.rs`**
  - Request/Response DTOs: `InstantAccountRequest`, `InstantAccountResponse`, `CustomAccountRequest`, `CustomAccountResponse`, `AppsCatalogResponse`, `HealthResponse`, `ConfigDiscoveryResponse`.
  - Error enum `DeltaChatError` mapping cleanly to HTTP Status and safe JSON responses.

---

### Phase 2: Registry Schema, JMAP & Defaults

- [x] **Task 2.1: Register `ObjectType::DeltaChat` in `crates/registry`**
  - In `crates/registry/src/schema/properties.rs`:
    - Add `ObjectInner::DeltaChat(DeltaChat)`.
    - Add `ObjectType::DeltaChat = 117`.
  - In `crates/registry/src/schema/properties_impl.rs`:
    - Update `EnumImpl for ObjectType` (`tiny_map!`, `as_str`, `from_id`, increment `COUNT: usize = 118`).
    - Add flags, permissions (`sysSystemSettings`), unpickle, and serialization forwarders.
  - In `crates/registry/src/schema/structs.rs` & `structs_impl.rs`:
    - Define `DeltaChat` struct matching settings fields.
    - Implement `ObjectImpl`, `Pickle`, `Default`, `IntoValue`, `RegistryJsonPropertyPatch`.

- [x] **Task 2.2: Register JMAP Get/Set Handlers in `crates/jmap`**
  - In `crates/jmap/src/registry/get.rs`: Add `| ObjectType::DeltaChat` to supported singletons.
  - In `crates/jmap/src/registry/set.rs`: Add `| ObjectType::DeltaChat` to supported singletons.

- [x] **Task 2.3: Add Safe Default Bootstrapping in `crates/common`**
  - In `crates/common/src/manager/defaults.rs` under `insert_safe_defaults`:
    - If `count_object(ObjectType::DeltaChat) == 0`, write default `DeltaChat` instance.

---

### Phase 3: WebUI Admin Settings (`resources/schema/schema.json`)

- [x] **Task 3.1: Update `resources/schema/schema.json`**
  - Decompress and edit `resources/schema/schema.json`:
    - In `layouts[1]` (Settings): Add `DeltaChat` container with 4 submenus:
      - `General` -> `x:DeltaChat/DeltaChatGeneral`
      - `Domains` -> `x:DeltaChat/DeltaChatDomains`
      - `Endpoints` -> `x:DeltaChat/DeltaChatEndpoints`
      - `Bot Protection` -> `x:DeltaChat/DeltaChatAltcha`
    - In `objects`: Add `x:DeltaChat` singleton and view entries.
    - In `schemas`: Add `x:DeltaChat`.
    - In `fields`: Add field metadata for general, domains, endpoints, and altcha.
    - In `forms`: Add 4 form layouts for the submenus.

- [x] **Task 3.2: Re-package Schema & Checksum**
  - Run:
    ```bash
    gzip -k9 -c schema.json > resources/schema/schema.json.gz
    sha256sum resources/schema/schema.json.gz | awk '{print $1}' > resources/schema/schema.json.sha256
    ```

---

### Phase 4: Altcha PoW & dclogin URI Engine

- [x] **Task 4.1: Implement `crates/deltachat/src/altcha.rs`**
  - HMAC-SHA256 challenge generation and constant-time signature verification.
  - Anti-replay protection with 120s TTL using `utils::cache::CacheWithTtl`.
  - Comprehensive unit tests for replay prevention and invalid challenge rejections.

- [x] **Task 4.2: Implement `crates/deltachat/src/dclogin.rs`**
  - DeltaChat setup link builder (`dclogin:<email>/?p=<password>&...`).
  - Unit tests verifying exact RFC/DeltaChat URL encoding and parameter order.

---

### Phase 5: Core REST Endpoints & WebXDC Catalog

- [x] **Task 5.1: Health & Config Handlers (`crates/deltachat/src/handlers/system.rs`)**
  - `GET /api/v1/health`: Uptime and version string.
  - `GET /api/v1/config`: Full connection metadata, endpoints, and Altcha settings.

- [x] **Task 5.2: Account Provisioning Handlers (`crates/deltachat/src/handlers/accounts.rs`)**
  - `POST /api/v1/accounts/instant`: Random email (`dc_hex`), CSPRNG password, Argon2id hash, registry write, `dclogin` link.
  - `POST /api/v1/accounts/custom`: Validation of username/domain/password, conflict check, registry write, `dclogin` link.

- [x] **Task 5.3: WebXDC App Store Handler & Catalog (`crates/deltachat/src/catalog.rs` & `handlers/apps.rs`)**
  - `GET /api/v1/apps`: Catalog JSON response.
  - Static package streaming under `/apps/xdcstore/*`.

---

### Phase 6: Embedded React SPA & HTTP Router Integration

- [x] **Task 6.1: Compile-Time Embedded Static Assets (`crates/deltachat/src/assets/web.rs`)**
  - Embed built React SPA assets (`../signup-relay/frontend/dist`).
  - Serve with appropriate `Content-Type`, `Cache-Control: public, max-age=31536000, immutable`, and fallback `index.html`.

- [x] **Task 6.2: Wire Dispatcher in `crates/http/src/request.rs`**
  - Route matching for `/api/v1/accounts/*`, `/api/v1/apps`, `/api/v1/health`, `/api/v1/config`, `/apps/xdcstore/*`, and SPA paths.
  - Dynamic runtime toggle: Return `404 Not Found` when `DeltaChat` is disabled.

---

### Phase 7: End-to-End Verification & Multi-Agent Review

- [x] **Task 7.1: Cargo Unit & Integration Tests**
  - Run `cargo test -p deltachat`.
  - Verify all tests pass.

- [x] **Task 7.2: Workspace Compilation & Linters**
  - Run `cargo check -p deltachat`.
  - Run `cargo check -p stalwart`.

- [x] **Task 7.3: Multi-Agent Review Pass**
  - Run `schema-reviewer` agent on schema and JMAP mappings.
  - Run `security-reviewer` agent on Altcha cryptography, password generation, and input sanitization.
  - Run `refactorer` agent for zero-copy efficiency and clean code compliance.
