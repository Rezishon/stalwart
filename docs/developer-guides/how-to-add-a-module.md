# Stalwart Module & Extension Developer Guide

This document outlines the architectural patterns, layers, and step-by-step procedures for extending or adding new modules to the Stalwart mail server—from core business logic up to the Web UI.

---

## 1. Architecture Overview

Stalwart is built as a modular multi-crate Cargo workspace (`crates/*`). Extensibility spans across four distinct layers:

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Frontend / WebUI Layer                                   │
│    - Schema-driven dynamic UI forms (via /api/schema)       │
│    - Dedicated custom React/Vite pages in WebUI bundle       │
└──────────────────────────────┬──────────────────────────────┘
                               │ HTTP / JMAP / REST API
┌──────────────────────────────▼──────────────────────────────┐
│ 2. HTTP & API Layer (crates/http)                           │
│    - URL routing in `crates/http/src/request.rs`            │
│    - Management endpoints in `crates/http/src/api/`         │
│    - Permissions & auth in `crates/http/src/auth/`          │
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│ 3. Schema & Configuration Layer (crates/registry & store)   │
│    - `ObjectType` in `crates/registry/src/schema/properties`│
│    - Typed structs in `crates/registry/src/schema/structs`  │
│    - JMAP registry mappings in `crates/jmap/src/registry/`  │
│    - Default bootstrapping in `crates/common/src/manager/`  │
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│ 4. Core Business Logic & Services                           │
│    - Dedicated crate (`crates/<module>`) or submodule       │
│    - Background tasks in `crates/services/src/task_manager` │
│    - Pipeline hooks in protocols (SMTP, IMAP, JMAP, etc.)   │
│    - Startup & lifecycle initialization in `crates/main`    │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Module Types & Extension Points

Depending on what you are building, pick the corresponding extension point:

| Extension Type | Primary Crates Involved | Description |
| :--- | :--- | :--- |
| **New Service / Background Worker** | `crates/services`, `crates/common` | Scheduled jobs, async workers, periodic sync, task queues. |
| **New Configurable Entity / Resource** | `crates/registry`, `crates/jmap`, `crates/store` | Objects managed via WebUI and API with full CRUD and persistence. |
| **New REST / HTTP Endpoint** | `crates/http` | Custom REST API routes, webhooks, integrations, or external HTTP handlers. |
| **Sieve / Script Engine Plugin** | `crates/common/src/scripts/plugins` | Custom scripting functions (DNS, LLM prompts, external API calls, header actions). |
| **New Protocol Server** | `crates/<proto>`, `crates/<proto>-proto`, `crates/main` | Low-level protocol listeners (like SMTP, IMAP, POP3, JMAP, ManageSieve). |
| **Web UI Dashboard / Custom View** | `resources/webui.zip` (upstream `stalwartlabs/webui`) | Administrative views, configuration screens, analytics dashboards. |

---

## 3. End-to-End Implementation Workflow

### Step 1: Core Logic & Storage
1. **Business Logic**:
   - For standalone subsystems, create a new workspace crate in `crates/<module-name>` and add it to root `Cargo.toml`.
   - For tasks and workers, implement under `crates/services/src/task_manager/<worker>.rs` and register it in `crates/services/src/task_manager/manager.rs`.
2. **Storage Persistence**:
   - If storing raw key-value or document data, leverage `crates/store` abstractions (`in_memory_store`, `rocksdb`, `s3`, etc.).

---

### Step 2: Registry & Configuration Schema (JMAP Persistence)

If the module requires user configuration via the Web UI or API, it must participate in the schema and JMAP registry persistence layer.

#### 1. Define Object Types (`crates/registry/src/schema/properties.rs` & `properties_impl.rs`)
- In `crates/registry/src/schema/properties.rs`:
  - Add enum variant to `pub enum ObjectInner`: `<ModuleName>(<ModuleName>),`
  - Add enum variant with explicit numeric discriminant to `pub enum ObjectType`: `<ModuleName> = <NextId>,`
- In `crates/registry/src/schema/properties_impl.rs`:
  - **`EnumImpl for ObjectType`**:
    - `parse()`: Add `b"<ModuleName>" => ObjectType::<ModuleName>,` in `hashify::tiny_map!`.
    - `as_str()`: Add `ObjectType::<ModuleName> => "<ModuleName>",`.
    - `from_id()`: Add mapping for numerical discriminant (e.g., `<NextId> => Some(ObjectType::<ModuleName>),`).
    - **`COUNT` constant trap**: Increment `const COUNT: usize = N;` to match total variants.
  - **Permissions & Flags**:
    - `flags()`: Add `ObjectType::<ModuleName> => <ModuleName>::FLAGS,` (use `OBJ_SINGLETON` for singletons or `0` / `OBJ_FILTER_*` for multi-instance entities).
    - `get_permission()`: Add `ObjectType::<ModuleName> => Permission::<GetPermission>,`.
    - `permissions()`: Add mutation permissions array `ObjectType::<ModuleName> => [Permission::<CreatePermission>, Permission::<UpdatePermission>, Permission::<DestroyPermission>],`.
  - **Serialization & Forwarding**:
    - `Object::unpickle()`: `ObjectType::<ModuleName> => Pickle::unpickle(stream).map(ObjectInner::<ModuleName>),`.
    - `Object::deserialize()`: `ObjectType::<ModuleName> => <ModuleName>::deserialize(deserializer).map(ObjectInner::<ModuleName>),`.
    - `From<ObjectType> for ObjectInner`: `ObjectType::<ModuleName> => ObjectInner::<ModuleName>(Default::default()),`.
    - `ObjectInner::object_type()`: `ObjectInner::<ModuleName>(_) => ObjectType::<ModuleName>,`.
    - `ObjectInner` method forwarders: Add `ObjectInner::<ModuleName>` match arms to `to_pickled_vec()`, `flags()`, `validate()`, `index()`, `patch()`, and `into_value()`.
  - **Bidirectional Conversions**:
    ```rust
    impl From<<ModuleName>> for ObjectInner {
        fn from(value: <ModuleName>) -> Self {
            ObjectInner::<ModuleName>(value)
        }
    }
    impl From<Object> for <ModuleName> {
        fn from(obj: Object) -> Self {
            match obj.inner {
                ObjectInner::<ModuleName>(obj) => obj,
                _ => unreachable!(),
            }
        }
    }
    ```

#### 2. Define Configuration Structs (`crates/registry/src/schema/structs.rs` & `structs_impl.rs`)
- In `crates/registry/src/schema/structs.rs`:
  ```rust
  #[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
  #[serde(default)]
  pub struct <ModuleName> {
      #[serde(rename = "fieldName")]
      pub field_name: <Type>,
  }
  ```
- In `crates/registry/src/schema/structs_impl.rs`:
  - Implement `ObjectImpl` (`FLAGS = OBJ_SINGLETON`, `VERSION = 0`, `OBJECT = ObjectType::<ModuleName>`).
  - Implement `Pickle` (`pickle` and `unpickle`).
  - Implement `Default`.
  - Implement `IntoValue` mapping properties into `JmapValue::Object`.
  - Implement `RegistryJsonPropertyPatch`:
    *Crucial:* Signature must declare `mut pointer: JsonPointerPatch<'_>` since `pointer.next_property()` mutates the pointer.
    ```rust
    impl RegistryJsonPropertyPatch for <ModuleName> {
        fn patch_property<'x>(
            &mut self,
            mut pointer: JsonPointerPatch<'_>,
            value: JmapValue<'x>,
        ) -> PatchResult<'x> {
            match pointer.next_property() {
                Some(Property::<PropertyName>) => self.field_name.patch(pointer, value),
                Some(Property::Type) => Ok(MaybeUnpatched::Unpatched {
                    property: Property::Type,
                    value,
                }),
                _ => Err(PatchError::new(pointer, "Invalid property")),
            }
        }
    }
    ```

#### 3. Register JMAP Get/Set Handlers (`crates/jmap`)
- In `crates/jmap/src/registry/get.rs`: Add `| ObjectType::<ModuleName>` to the supported objects pattern match in `handle_registry_get`.
- In `crates/jmap/src/registry/set.rs`: Add `| ObjectType::<ModuleName>` to the supported objects pattern match in `handle_registry_set`.
- *Note on "Object not found":* If an object is configured in `schema.json` but missing from `crates/jmap/src/registry/get.rs` or the database, the WebUI displays an `"Object not found"` red banner and the **Save** button cannot persist changes.

#### 4. Define Default Bootstrap Configuration (`crates/common`)
- In `crates/common/src/manager/defaults.rs` under `insert_safe_defaults(bp)`:
  ```rust
  if bp.registry.count_object(ObjectType::<ModuleName>).await? == 0 {
      bp.registry
          .write(RegistryWrite::insert(
              &<ModuleName> {
                  field_name: <DefaultValue>,
                  ..Default::default()
              }
              .into(),
          ))
          .await?;
  }
  ```

---

### Step 3: HTTP API & Routing
If the module exposes dedicated HTTP endpoints, use one of the two routing models:

#### 1. Direct REST Endpoint under `/api/<endpoint>` (`crates/http/src/api/mod.rs`)
All requests with prefix `/api/*` route into `handle_api_request` in `crates/http/src/api/mod.rs`.
Add a match arm to the path dispatcher:

```rust
"<endpoint_name>" => {
    // 1. Authorization & RBAC (optional):
    // let (_in_flight, access_token) = self.authenticate_headers(req, session).await?;
    // access_token.enforce_permission(Permission::<RequiredPermission>)?;

    // 2. Read request body if needed (is_post):
    if is_post {
        let body_bytes = body.ok_or_else(|| trc::LimitEvent::SizeRequest.into_err())?;
        // Parse JSON or process payload...
    }

    // 3. Return HttpResponse:
    Ok(HttpResponse::new(StatusCode::OK)
        .with_no_cache()
        .with_header(hyper::header::CONTENT_TYPE, "application/json")
        .with_text_body(r#"{"status":"ok"}"#))
}
```

#### 2. Root Custom Route or Standalone Sub-module (`crates/http/src/request.rs` & `crates/http/src/api/<module>.rs`)
For top-level paths (e.g. `/<module>` outside of `/api/`) or modular handlers:
1. **Route Dispatching**: Update `parse_http_request` in `crates/http/src/request.rs` to match the path prefix.
2. **Endpoint Handler**: Implement complex handler logic in a dedicated file `crates/http/src/api/<module>.rs` and register the module in `crates/http/src/api/mod.rs`.
3. **Authorization & RBAC**: Enforce permissions using `crates/http/src/auth/permissions.rs` via `access_token.enforce_permission(Permission::<RequiredPermission>)`.

---

### Step 4: Server Lifecycle Wiring
1. In `crates/main/src/main.rs`:
   - Initialize the module during server boot (`BootManager::init()`).
   - Spawn listeners or workers within `init.start_services().await` or `init.servers.spawn()`.
   - Handle graceful shutdown signals with `wait_for_shutdown().await`.

---

### Step 5: Web UI Integration & Schema Configuration

1. **Schema-driven Forms & Layouts**:
   - Stalwart's Web UI dynamically renders configuration forms and navigation trees directly from `/api/schema`.
   - Schema definitions reside in `resources/schema/schema.json.gz` with its checksum in `resources/schema/schema.json.sha256`.
   - The schema JSON consists of 6 primary sections:
     - **`layouts`**: Defines the sidebar navigation trees (e.g., `layouts[0]` = Management, `layouts[1]` = Settings). Navigation items are declared as `{ "link": { "name": "...", "icon": "...", "viewName": "x:..." } }` or inside `{ "container": { ... } }`.
     - **`objects`**: Declares entity metadata, including `type` (`"singleton"` or `"object"`), `permissionPrefix`, and `description`.
     - **`schemas`**: Maps the schema name and structure (`"single"`, `"composite"`).
     - **`fields`**: Property definitions, types (`"boolean"`, `"string"`, `"secret"`, `"duration"`), defaults, and update mutability.
     - **`forms`**: Form presentation layout (titles, subtitles, sections, field lists).
     - **`lists`**: List view configurations for multi-instance objects.

2. **Permission Prefix & Navigation Visibility (`permissionPrefix`)**:
   - **Crucial Rule**: The WebUI filters sidebar navigation items based on user role permissions. It calls `hasObjectPermission(object.permissionPrefix, 'Get')` before rendering any item.
   - If an object uses a new permission prefix, that permission must either:
     a. Be added to the backend `Permission` enum in `crates/common/src/auth/permissions.rs` and granted to the target role/token, OR
     b. Reuse an existing admin prefix that the administrator already possesses (such as `sysEnterprise` or `sysSystemSettings`).
   - If `permissionPrefix` is unassigned or unknown to the user's token, the WebUI will silently hide the menu item.

3. **Packaging Schema Changes**:
   - Schema files are embedded into the `http` crate at compile-time via `include_bytes!("../../../../resources/schema/schema.json.gz")`.
   - After updating `schema.json`:
     ```bash
     gzip -k9 -c schema.json > resources/schema/schema.json.gz
     sha256sum resources/schema/schema.json.gz | awk '{print $1}' > resources/schema/schema.json.sha256
     ```
   - Recompile the server binary (`cargo run -p stalwart` / `cargo build`) so the embedded bytes and checksum update.
   - The browser caches `/api/schema/<hash>` with immutable cache headers. Always perform a hard refresh (**`Ctrl + Shift + R`** or **`Cmd + Shift + R`**) after updating the schema.

4. **Custom Frontend Pages & Integration Options**:

Choose one of the 3 frontend strategies based on architectural needs:

| Strategy | When to Choose | Key Files / Extension Points |
| :--- | :--- | :--- |
| **Option A: Dynamic Admin View (Schema-Driven)** | Best for CRUD management forms, settings toggles, and standard admin controls inside `/admin`. Zero JavaScript coding required. | `resources/schema/schema.json` |
| **Option B: Standalone Web Application (SPA Bundle)** | Best for dedicated complex interfaces (React, Vue, Svelte, or full dashboards) hosted under a custom prefix like `/<app-name>/`. | `crates/common/src/manager/application.rs`, `Application` struct, `.zip` bundle |
| **Option C: Direct Server-Rendered HTML Route** | Best for lightweight static pages, landing screens, webhooks, or simple interactive widgets without client bundlers. | `crates/http/src/request.rs` |

##### Option A: Schema-Driven View in Admin Dashboard (`/admin`)
1. **WebUI Bundle (`resources/webui.zip`)**:
   - Static WebUI assets are served from `resources/webui.zip` via `crates/common/src/manager/application.rs` at `/admin` and `/account`.
   - For custom React components from `stalwartlabs/webui` or custom frontend event hooks/scripts, assets are bundled directly into `resources/webui.zip`.
2. Add navigation link in `resources/schema/schema.json` under `layouts`:
   ```json
   { "link": { "name": "My Module", "icon": "settings", "viewName": "x:my_module" } }
   ```
3. Define object schema under `objects`, `fields`, and `forms`.
4. Re-package schema (`gzip -k9 -c schema.json > resources/schema/schema.json.gz && sha256sum resources/schema/schema.json.gz | awk '{print $1}' > resources/schema/schema.json.sha256`).

##### Option B: Standalone Single-Page Web Application (`/<app-name>/`)
1. Build the SPA frontend into a static `.zip` archive containing `index.html` and assets.
2. Register the application in database/bootstrapper (`crates/common/src/manager/defaults.rs`):
   ```rust
   Application {
       enabled: true,
       prefixes: vec!["<app-name>".to_string()],
       url: "https://.../bundle.zip".to_string(), // or blob store reference
       ..Default::default()
   }
   ```
3. Stalwart automatically extracts and serves the application at `http://<host>:8080/<app-name>/`.

##### Option C: Direct Server-Rendered Route (`crates/http/src/request.rs`)
1. In `crates/http/src/request.rs` within `parse_http_request`:
   ```rust
   "<custom-page>" => {
       return Ok(HttpResponse::new(StatusCode::OK)
           .with_content_type("text/html; charset=utf-8")
           .with_text_body(r#"<!DOCTYPE html>
   <html>
     <head><title>Custom View</title></head>
     <body><h1>Custom Page</h1></body>
   </html>"#));
   }
   ```
2. Access directly at `http://<host>:8080/<custom-page>`.

---

## 4. End-to-End Build & Run Workflow

### Running in Development:

#### 1. Direct on Host:
```bash
cargo run -p stalwart --no-default-features --features "sqlite enterprise" -- -c /var/lib/stalwart/config.json
```

#### 2. Inside Docker Dev Container:
Start the dev container with port mappings:
```bash
# Start container interactively:
docker compose run --rm -it -p 8080:8080 -p 2525:25 -p 993:993 stalwart-dev bash

# Or start in background and attach:
docker compose up -d stalwart-dev
docker compose exec -it stalwart-dev bash
```

Inside the container:
```bash
cargo run -p stalwart --no-default-features --features "sqlite enterprise" -- -c /var/lib/stalwart/config.json
```

### Verification Steps:
1. **API Direct Test**: Test the HTTP endpoint using `curl`:
   ```bash
   curl -X POST http://localhost:8080/api/<module> \
     -H "Content-Type: application/json" \
     -d '{"enabled": true}'
   ```
2. **WebUI Browser Test**:
   - Open `http://localhost:8080/admin`
   - Hard refresh (`Ctrl + Shift + R`) to pull the updated schema.
   - Check sidebar menu and test UI components.

---

## 5. Verification & Testing Checklist

- [ ] **Unit / Integration Tests**: Add tests under `tests/` or crate-level `tests/`.
- [ ] **Schema Check**: Ensure serialization and deserialization (`Pickle`, `serde_json`, `serde_cbor`) pass round-trip tests.
- [ ] **Permission Mapping**: Verify `permissionPrefix` is granted to the user's role or token.
- [ ] **Checksum & Gzip Sync**: Verify `schema.json.sha256` matches `sha256sum schema.json.gz`.
- [ ] **Security Boundaries**: Verify authentication enforcement and loopback/anonymous access guards in `crates/http/src/request.rs`.
- [ ] **Graceful Shutdown**: Confirm background tasks respond cleanly to broadcast shutdown signals.
