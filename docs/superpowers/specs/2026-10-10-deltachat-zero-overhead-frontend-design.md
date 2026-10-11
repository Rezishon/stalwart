# Technical Specification & R&D Report: Stalwart Core for DeltaChat
**Document ID:** `SPEC-2026-10-10-DELTACHAT-ZERO-OVERHEAD`  
**Status:** Ready for Multi-Agent & Team Review  
**Author:** AI R&D Team & Lead Architect  
**Target Audience:** Core Rust Developers, Frontend React Developers, Security & Schema Reviewers  

---

## 1. Executive Summary & Problem Statement

### 1.1 Objective
Transform this Stalwart mail server repository into a specialized, high-performance, single-binary core for the **DeltaChat ecosystem** (serving as a replacement/enhancement for chatmail and other server backends). 

### 1.2 Core Constraints
1. **Absolute Zero VPS Overhead & Friction**:
   - The server must run as a single monolithic Linux/BSD/macOS binary (`./stalwart -c config.json`).
   - **Zero** external runtime dependencies: no Docker, no Node.js/npm, no Python scripts, no external package installations.
   - **Zero** file copying/pasting, zip/unzip operations, or runtime temporary file extractions.
   - Run the binary and the entire system (SMTP, IMAP, JMAP, Onboarding Web UI, and Admin WebUI) is instantly live.
2. **Dedicated User Onboarding Frontend (React)**:
   - Dedicated frontend for account creation (username/password), invite handling, and generating DeltaChat login URLs / QR codes.
   - Mounted at root `/` and clean paths such as `/app`, `/description`, etc.
   - Developed independently as a modern React (Vite / TypeScript / Tailwind) project without burdening backend development.
3. **DeltaChat Administrative Module in WebUI**:
   - Integrated directly into Stalwart’s existing WebUI under the **Settings** menu.
   - Feature toggle: Can be turned **On** or **Off**.
   - Multiple sub-configuration views, notably including a **Relay Page** configuration.
   - **Extensible Default**: By default, the server serves the embedded zero-overhead React frontend. If an administrator wishes to supply their own custom frontend directory or URL, they can configure it through this Relay Page setting.
4. **Code Quality Standards**:
   - Strict adherence to **KISS** (Keep It Simple, Stupid), **DRY** (Don't Repeat Yourself), and **Clean Code**.
   - Alignment with Stalwart's architectural patterns as documented in `docs/developer-guides/how-to-add-a-module.md`.

---

## 2. React Frontend Development Contract & Workflow

### 2.1 Can the React project continue independently?
**YES, 100%.** There is zero conflict between developing the frontend as an independent React project and serving it with zero overhead from the Stalwart binary. In fact, this decoupled architecture is the industry standard for single-binary Rust appliances (similar to Grafana, HashiCorp Nomad, PocketBase, and MinIO).

### 2.2 How React Integrates with the Rust Monolith

```
┌─────────────────────────────────┐           ┌────────────────────────────────────────┐
│  React Project (Vite + TS)      │           │  Stalwart Rust Workspace               │
│  (Independent Repo / Submodule) │           │  (crates/*)                            │
├─────────────────────────────────┤           ├────────────────────────────────────────┤
│  src/                           │           │  crates/http/src/request.rs            │
│  ├── App.tsx                    │           │  crates/registry/                      │
│  ├── pages/ (Onboarding, Login) │           │  crates/jmap/                          │
│  └── api/client.ts              │           │  resources/onboarding-dist/            │
└────────────────┬────────────────┘           └──────────────────▲─────────────────────┘
                 │                                               │
                 │ npm run build                                 │ build.rs / rust-embed
                 ▼                                               │
          dist/ (Static Files) ──────────────────────────────────┘
          (index.html, .js, .css)          (Baked into .rodata binary memory)
```

### 2.3 Frontend Technical Contract (Vite Configuration)
To guarantee zero-friction embedding into Rust, the React project should adhere to the following simple build rules:

1. **Relative Asset Base**:
   Configure Vite to output relative paths so assets resolve cleanly under `/`, `/app/`, or subpaths:
   ```ts
   // vite.config.ts
   import { defineConfig } from 'vite';
   import react from '@vitejs/plugin-react';

   export default defineConfig({
     plugins: [react()],
     base: '/', // or './' for relative asset links
     build: {
       outDir: 'dist',
       emptyOutDir: true,
     },
     server: {
       // Dev Mode: Proxy API requests directly to running Stalwart core
       proxy: {
         '/api': 'http://localhost:8080',
         '/jmap': 'http://localhost:8080',
       },
     },
   });
   ```

2. **Client-Side Routing (SPA)**:
   Use standard React Router (`react-router-dom` or lightweight router). Because Stalwart's HTTP layer will fall back to `index.html` for non-file requests, client-side URLs like `/app`, `/description`, `/setup` work natively with full browser refresh and history support.

3. **API Contract with Stalwart**:
   The frontend will talk to Stalwart using standard JSON REST requests:
   - `POST /api/deltachat/register`: Creates the user account and returns the DeltaChat login setup URL.
   - `GET /api/deltachat/info`: Returns server status, open registration policy, and server public domain.

---

## 3. Zero-Overhead In-Binary Asset Serving Architecture

### 3.1 Why Current Stalwart WebUI Has Overhead
Stalwart's existing `WebApplications` manager (`crates/common/src/manager/application.rs`) operates as follows:
1. Downloads `webui.zip` or reads from `/workspace/resources/webui.zip`.
2. Extracts files to a temporary folder in `/tmp/<timestamp>`.
3. Populates an in-memory hash map of file paths pointing to disk paths.
4. On every HTTP request, calls `tokio::fs::read(&resource.contents).await`.

**Consequences**: Requires write access to `/tmp`, consumes disk space, hits filesystem I/O on every request, and fails on air-gapped or read-only VPS filesystems if internet or disk is unavailable.

### 3.2 Evaluation of Architectural Options (MECE Comparison)

| Dimension | Option 1: First-Run Disk Extraction | Option 2: Current Zip Resource Pattern | Option 3: Compile-Time In-Binary `.rodata` Embedding (RECOMMENDED) |
| :--- | :--- | :--- | :--- |
| **VPS Dependencies** | Low (needs writable filesystem) | High (requires `.zip` on disk or internet) | **Zero (single binary only)** |
| **Runtime Disk I/O** | High (`tokio::fs::read` per hit) | High (`tokio::fs::read` per hit) | **Zero (served directly from RAM / OS page cache)** |
| **First-Boot Latency** | Slow (writes hundreds of files) | Slow (unzip blocking threads) | **Instant (0 ms startup delay)** |
| **Binary Size Impact**| Zero (assets separate) | Zero (assets separate) | +300 KB to ~1.5 MB (gzipped React assets) |
| **Failure Modes** | Disk full, read-only FS, permissions | Network timeout, corrupt ZIP, orphan files | **None (impossible to lose or corrupt)** |

### 3.3 Chosen Approach: Pre-Compressed In-Binary Memory Serving
Using `rust-embed` (or `include_dir!` with build-time gzip):
1. **At Compile Time**: Assets in `resources/onboarding-dist/` are pre-compressed with Gzip (`level 9`).
2. **At Runtime**:
   - The embedded file is a static slice `&'static [u8]` stored in the binary's read-only data section (`.rodata`).
   - Served directly with `Content-Encoding: gzip`.
   - The CPU never re-compresses assets, and the disk is never touched.
   - Hashed static assets (`/assets/*.js`, `/assets/*.css`) receive:
     `Cache-Control: public, max-age=31536000, immutable`
   - Entry point (`index.html`) receives:
     `Cache-Control: no-cache` with `ETag`.

---

## 4. HTTP Routing & Dynamic Dispatch Specification

In `crates/http/src/request.rs`, the request parser routes incoming HTTP connections.

### 4.1 Route Map & Precedence

```
Incoming Request
 │
 ├── Starts with /admin or /account   ──► Existing Stalwart WebUI (Application manager)
 ├── Starts with /jmap, /dav, /.well-known ──► Core mail protocols & APIs
 ├── Starts with /api/deltachat       ──► DeltaChat REST API (Registration & status)
 ├── Matches static asset (/assets/*, /favicon.ico, etc.)
 │    └── If Relay Page = Custom      ──► Serve from custom disk directory
 │    └── If Relay Page = Default     ──► Serve from In-Binary Embedded Memory
 └── Any other GET (/, /app, /description) [SPA Fallback]
      └── If Relay Page = Custom      ──► Serve custom index.html
      └── If Relay Page = Default     ──► Serve embedded index.html
```

### 4.2 Handling the "Relay Page" Extensibility Requirement
The user requirement states:
> *"one of that items in that deltachat menu should be a Relay Page config. which first should be default but users will be able to update it with thier frontend too. the most important is having zero dependency at first, but anyone if want to add thier frontend they can too."*

To satisfy this cleanly without sacrificing zero-overhead:
1. `DeltaChatSettings.relay_page_type` enum has two values:
   - `Default`: Uses the embedded zero-overhead compiled React frontend.
   - `Custom`: Points to a local filesystem path or external URL.
2. In `crates/http/src/request.rs`:
   ```rust
   // Check DeltaChat settings from memory cache
   let dc_settings = self.inner.data.deltachat.get();
   if dc_settings.enabled {
       match &dc_settings.relay_page {
           RelayPageConfig::Default => {
               // Zero-overhead in-memory embedded asset serving
               return self.serve_embedded_onboarding(path, req).await;
           }
           RelayPageConfig::Custom(custom_path) => {
               // Serve files from administrator's custom frontend directory
               return self.serve_custom_static_path(custom_path, path, req).await;
           }
       }
   }
   ```

---

## 5. DeltaChat Public Onboarding & Account API

### 5.1 Endpoint: `POST /api/deltachat/register`
Allows the onboarding React frontend to register a new user and generate their DeltaChat login URI.

#### Request Payload:
```json
{
  "username": "alice",
  "password": "SecurePassword123!",
  "invite_code": "optional-invite-token"
}
```

#### Processing Pipeline:
1. **Pre-flight Checks**:
   - Check if `DeltaChatSettings.enabled == true`. Return `403 Forbidden` if disabled.
   - Check if `DeltaChatSettings.allow_open_registration == true` (or validate `invite_code`).
   - Rate limit check on remote IP (using Stalwart's `is_http_anonymous_request_allowed`).
2. **Account Creation**:
   - Construct an `Account` entity in `store`.
   - Email address defaults to `<username>@<primary_domain>`.
   - Set password hash (Argon2id via Stalwart's existing authentication password hasher).
   - Write to registry store via `RegistryWrite::insert`.
3. **DeltaChat Setup URI Generation**:
   DeltaChat clients configure accounts via a standard setup URL / QR code format:
   ```
   OPENPGP4FPR:<fingerprint>#smtp=<domain>:465&imap=<domain>:993&user=<email>&pass=<password>
   ```
   Or standard DeltaChat QR login URI:
   ```
   dcaccount:<base64-json-or-query-string>
   ```
   The backend generates and returns this payload so the React frontend can immediately render a QR code on-screen for the user to scan with their mobile DeltaChat app.

#### Response Payload:
```json
{
  "status": "success",
  "email": "alice@example.com",
  "login_url": "dcaccount:v1?user=alice%40example.com&pass=...&smtp=mail.example.com%3A465&imap=mail.example.com%3A993",
  "qr_payload": "dcaccount:v1?..."
}
```

---

## 6. WebUI Admin Module & Configuration Schema

To ensure **DRY** and **Clean Code**, the DeltaChat configuration does NOT require custom JavaScript in the Stalwart WebUI. It leverages Stalwart’s existing schema engine (`resources/schema/schema.json.gz`), which dynamically generates reactive forms and validation.

### 6.1 Registry Schema Entity (`crates/registry/src/schema/`)

#### Data Model (`DeltaChatSettings` Struct):
```rust
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeltaChatSettings {
    pub enabled: bool,
    pub allow_registration: bool,
    pub primary_domain: String,
    pub default_quota_bytes: u64,
    pub relay_page_mode: RelayPageMode,
    pub custom_relay_path: Option<String>,
    pub invite_required: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum RelayPageMode {
    EmbeddedDefault,
    CustomPath,
}
```

### 6.2 Schema Registration Steps (per `how-to-add-a-module.md`)
1. **`crates/registry/src/schema/properties.rs`**:
   - Add `DeltaChat(DeltaChatSettings)` to `pub enum ObjectInner`.
   - Add `DeltaChat = 120` to `pub enum ObjectType`.
2. **`crates/registry/src/schema/properties_impl.rs`**:
   - Register parser name `b"DeltaChat" => ObjectType::DeltaChat`.
   - Map permissions: `ObjectType::DeltaChat => Permission::Admin`.
   - Mark as singleton: `OBJ_SINGLETON`.
   - Increment `const COUNT: usize` in `EnumImpl for ObjectType`.
3. **`crates/jmap/src/registry/get.rs` & `set.rs`**:
   - Add match arm for `ObjectType::DeltaChat` to allow standard JMAP read/write of settings.
4. **`crates/common/src/manager/defaults.rs`**:
   - Seed default `DeltaChatSettings` during bootstrap:
     ```rust
     DeltaChatSettings {
         enabled: true,
         allow_registration: true,
         primary_domain: bp.registry.local_hostname().to_string(),
         default_quota_bytes: 1024 * 1024 * 1024, // 1 GB
         relay_page_mode: RelayPageMode::EmbeddedDefault,
         custom_relay_path: None,
         invite_required: false,
     }
     ```

### 6.3 WebUI Navigation Menu Placement (`resources/schema/schema.json`)
Added under the `Management` or `Settings` section in `layouts`:
```json
{
  "container": {
    "name": "DeltaChat",
    "icon": "message-square",
    "items": [
      {
        "name": "General Settings",
        "type": "link",
        "viewName": "x:DeltaChat/General"
      },
      {
        "name": "Relay Page Config",
        "type": "link",
        "viewName": "x:DeltaChat/RelayPage"
      },
      {
        "name": "Invites & Security",
        "type": "link",
        "viewName": "x:DeltaChat/Security"
      }
    ]
  }
}
```

---

## 7. Clean Code, KISS & DRY Module Architecture

To maintain pristine codebase organization, all new logic must be isolated in its designated architectural layer rather than being scattered:

```
stalwart/
├── crates/
│   ├── deltachat/                    <-- Dedicated new crate for DeltaChat domain logic
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── lib.rs
│   │       ├── api.rs                (Registration & setup URI builders)
│   │       ├── embedded_assets.rs    (rust-embed memory asset provider)
│   │       └── qr.rs                 (QR code generator utilities)
│   ├── http/
│   │   └── src/request.rs            <-- Lightweight route dispatch to crates/deltachat
│   ├── registry/
│   │   └── src/schema/               <-- DeltaChatSettings struct & ObjectType enum
│   ├── jmap/
│   │   └── src/registry/             <-- JMAP CRUD handlers for DeltaChatSettings
│   └── common/
│       └── src/manager/defaults.rs   <-- Default bootstrap insertion
└── resources/
    ├── onboarding-dist/              <-- Built React static assets (.html, .js, .css)
    └── schema/schema.json.gz         <-- WebUI schema containing DeltaChat menus & forms
```

### Why this is Clean, DRY & KISS:
- **Clean Separation of Concerns**: Core mail protocols (SMTP/IMAP) remain 100% untouched.
- **KISS**: We don't write complex file extraction code or background zip managers; we embed static bytes directly into `.rodata`.
- **DRY**: WebUI admin controls reuse Stalwart’s existing schema engine rather than duplicating React components or custom frontend state machines.

---

## 8. Multi-Agent Review & Quality Assurance Plan

Before implementation code is merged, the change will run through the sequential review pipeline defined in `.claude/skills/agents-flow/SKILL.md`:

1. **`schema-reviewer`**:
   - Verifies `schema.json.gz` syntax, layouts, and field definitions.
   - Ensures `ObjectType::DeltaChat` discriminant and `COUNT` constant match exactly in `crates/registry`.
   - Confirms JMAP registry `get.rs` and `set.rs` bindings are properly synchronized.
2. **`security-reviewer`**:
   - Audits `POST /api/deltachat/register` against brute-force attacks and denial-of-service.
   - Verifies that registration cannot bypass email format validation, domain validation, or quota bounds.
   - Audits password hashing to ensure it routes through Argon2id.
3. **`refactorer`**:
   - Ensures static asset serving is truly zero-copy and non-blocking (zero synchronous disk reads).
   - Validates that no unnecessary allocations take place in hot HTTP dispatch loops.
   - Enforces YAGNI (deletes unnecessary boilerplate).
4. **`verifier`**:
   - Executes `cargo check -p deltachat -p http -p registry -p stalwart`.
   - Runs unit tests for DeltaChat setup URI generation and account registration logic.

---

## 9. Recommendations for the Frontend Team (Actionable Next Steps)

1. **Continue developing the React project without hesitation**:
   - Focus on user experience: username selection, domain selector, password strength meter, DeltaChat QR code display, and "Open in DeltaChat" deep-linking button (`chat.delta.app/login#...`).
2. **Mock API during frontend development**:
   - In React, use a simple mock or the Vite proxy pointing to a stubbed response for `POST /api/deltachat/register`.
3. **Build verification**:
   - Periodically run `npm run build` and ensure the output in `dist/` contains only static files (`index.html`, `/assets/*.js`, `/assets/*.css`).
   - When ready, the contents of `dist/` simply copy into `resources/onboarding-dist/` before final binary compilation.
