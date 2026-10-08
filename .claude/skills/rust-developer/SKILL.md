---
name: rust-developer
description: Architectural rules, async idioms, error handling with trc, zero-copy, and multi-crate patterns for Stalwart Rust codebase.
---

# Stalwart Rust Developer Guide

## Core Architectural Rules
1. **Multi-Crate Workspace**: Stalwart is organized under `crates/*`. Keep cross-crate dependencies strictly unidirectional (e.g. `main` -> `http` -> `jmap` -> `store` -> `common` -> `types`/`trc`).
2. **Error Handling via `trc`**:
   - Use `trc::Result<T>` and the `trc` event system across all service and protocol boundaries.
   - Attach context using `.ctx(trc::Key::Details, "...")` or `.into_err()`.
   - Never use raw panics (`unwrap()`, `expect()`) in network request paths.
3. **Async Runtime (Tokio & Hyper v1)**:
   - Structure network handlers around `tokio` async streams and `hyper` v1 `HttpRequest` / `HttpResponse`.
   - Never hold standard sync locks across `.await` points.
4. **Registry & Schema Sync**:
   - When introducing configurable entities, follow the 4-step chain:
     1. Enum in `crates/registry/src/schema/properties.rs` & `properties_impl.rs` (update `COUNT`).
     2. Struct in `crates/registry/src/schema/structs.rs` & `structs_impl.rs` (`Pickle`, `IntoValue`, `RegistryJsonPropertyPatch`).
     3. JMAP Get/Set match in `crates/jmap/src/registry/get.rs` and `set.rs`.
     4. Default bootstrap in `crates/common/src/manager/defaults.rs`.
5. **Zero-Copy & Allocations**:
   - Prefer `CompactString`, `&str`, `&[u8]`, and `Bytes` over allocating new `String` or `Vec<u8>` on hot parsing paths.
6. **Testing**:
   - Run targeted crate check: `cargo check -p <crate>@0.16.25`.
   - Run unit tests: `cargo test -p <crate>@0.16.25 --lib`.
