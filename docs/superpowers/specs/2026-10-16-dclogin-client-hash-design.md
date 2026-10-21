# Design: Configurable DCLogin endpoints and client-side password hashing

**Document ID:** `SPEC-2026-10-16-DCLOGIN-CLIENT-HASH`
**Status:** Approved
**Date:** 2026-10-16
**Target:** `crates/deltachat` (primary), minimum core seams listed in §5, `signup-relay/frontend` (TypeScript)
**Principles:** Clean Code, DRY, KISS. No hardcoded hosts, ports, security, `ic`, or hash algorithm.

---

## 1. Objective

1. Advertise IMAP/SMTP connection parameters and certificate policy from the DeltaChat admin Endpoints form. The SPA builds `dclogin:` URIs. The backend never returns a `dclogin_link` or plaintext password.
2. Use one password hash algorithm for the whole server: existing Authentication `passwordHashAlgorithm`. Copy it into public `GET /api/v1/config`. The SPA hashes; the backend stores the hash only if it matches that algorithm.

Out of scope: Django `signup-relay/backend`, static sites `dc.tabarestangnu.ir` / `delta.sudoshz.ir`, split IMAP/SMTP credentials (`iu` `ipw` `su` `spw`), `sc`.

---

## 2. Current state (defects)

| Location | Defect |
|---|---|
| `crates/deltachat/src/dclogin.rs` | Hardcodes `ic=3`. |
| `crates/deltachat/src/config.rs` | `EndpointSecurity` is only `ssl`/`starttls`. Endpoints inferred from `server_name` + ports `993`/`465`. |
| `registry::schema::structs::DeltaChat` | No endpoint or `ic` fields. Admin has General / Domains / Altcha only. Spec already named Endpoints; it was never stored. |
| `handlers/accounts.rs` | Server generates `dc_` username + password, hashes with hardcoded `Argon2id`, returns `dclogin_link` + plaintext. |
| `http/src/auth/oauth/registration.rs` | OAuth client secret hashed with hardcoded `Argon2id`. |
| SPA `utils/dclogin.ts` | Defaults `mail.{domain}`, `993`, `465`, `ssl`, `ic=3`. |
| SPA onboarding | Expects backend to return `dclogin_link`. Custom wizard POSTs plaintext. |

---

## 3. DCLogin keys

Must-have (admin + config + URI):

| key | meaning | values |
|---|---|---|
| `ih` / `ip` / `is` | IMAP host / port / security | security: `ssl`, `starttls`, `default`, `plain` |
| `sh` / `sp` / `ss` | SMTP host / port / security | same |
| `ic` | cert checks for IMAP and SMTP | `0` Automatic, `1` Strict, `3` AcceptInvalid |

Skip: `iu` `ipw` `su` `spw` `sc`.

`p` is the plaintext mailbox password. It belongs only in the in-memory URI. It is never POSTed.

---

## 4. Hash algorithm (unified)

Source of truth: `Authentication.passwordHashAlgorithm` → `server.core.network.security.password_hash_algorithm`.

Values: `argon2id` (default), `bcrypt`, `scrypt`, `pbkdf2`.

Do not add a DeltaChat-only hash field.

All server-side hashing of new secrets (account passwords via JMAP, OAuth client secrets, any remaining server-side hash) uses that value. Login verification stays prefix-based (`verify_secret_hash`) so existing hashes of other algorithms still work.

Public copy: `GET /api/v1/config` includes `password_hash_algorithm` as those four lowercase strings. The SPA does not call JMAP.

---

## 5. Admin (WebUI) and what is outside `crates/deltachat`

Business logic stays in the module. Stalwart admin is schema-driven, so **three core seams** must change. Nothing else in core mail (SMTP/IMAP listeners, directory `hash_secret`, JMAP account password mapping) needs a new code path — those already take `Authentication.passwordHashAlgorithm`.

| Change | Where | Why it is outside the crate |
|---|---|---|
| Seven endpoint/`ic` fields on singleton `x:DeltaChat` | `crates/registry` (`structs.rs`, `structs_impl.rs`, `properties.rs`, `properties_impl.rs`) | Persistence and JMAP property ids live in registry, not in `deltachat`. Same pattern as existing DeltaChat fields. |
| Endpoints menu + form | `resources/schema/schema.json.gz` (+ sha256) | WebUI reads this gzip, not crate code. |
| OAuth client secrets | `crates/http/src/auth/oauth/registration.rs` | One leftover `PasswordHashAlgorithm::Argon2id` so “unified hash” is actually whole-server. |

Do **not** change: Authentication form (already has the algorithm), IMAP/SMTP bind addresses, `directory::hash_secret` (already parameterized), JMAP mailbox password hashing (already uses the setting).

Add **Endpoints** under the existing DeltaChat menu (`x:DeltaChat/DeltaChatEndpoints`).

Fields on the `x:DeltaChat` singleton:

- `imapHost` string
- `imapPort` unsigned integer
- `imapSecurity` enum `ssl` `starttls` `default` `plain`
- `smtpHost` string
- `smtpPort` unsigned integer
- `smtpSecurity` same enum
- `certificateChecks` enum `0` `1` `3` (serialize in config as string `"0"` `"1"` `"3"`)

Empty `imapHost` or `smtpHost` is invalid for signup. Do not substitute `localhost` or `server_name`.

Hash algorithm stays on the existing Authentication form.

Pickle: bump `DeltaChat` `VERSION` from 2 to 3. Unpickle v2 blobs, then read the seven new fields when version >= 3.

Registry `Property` discriminants start at 949 (`ImapHost` …). `Property::COUNT` becomes 956.

`crates/registry/src/schema/{properties,structs,enums}*.rs` are marked auto-generated; this repo already edits them by hand for DeltaChat. Continue that pattern. Do not invent a generator.

---

## 6. Public config

`GET /api/v1/config` (only public discovery URL for the SPA):

```json
{
  "domain": "example.org",
  "registration_open": true,
  "instant_accounts_enabled": true,
  "custom_accounts_enabled": true,
  "password_hash_algorithm": "argon2id",
  "certificate_checks": "3",
  "endpoints": {
    "imap": { "host": "mail.example.org", "port": 993, "security": "ssl" },
    "smtp": { "host": "mail.example.org", "port": 465, "security": "ssl" }
  },
  "altcha": { "required": false, "max_number": 100000 }
}
```

If endpoint hosts are empty, still return 200 for health/discovery, but account POST returns `400` `endpoints_not_configured`. If `password_hash_algorithm` is missing from Authentication, that is a server bug (always has a default).

---

## 7. Account POST

Instant and custom both accept:

```json
{
  "username": "alice",
  "password_hash": "$argon2id$v=19$m=19456,t=2,p=1$...",
  "altcha_payload": "..."
}
```

Instant and custom usernames both come from the SPA. **Delete** `generate_instant_credentials` (no `dc_` generator, no password generator on the server). Instant POST still **validates** `username` as `^dc_[0-9a-f]{12}$` so the reserved prefix cannot be used for custom names and random instant names stay well-formed. Custom: existing `validate_username`; `dc_` prefix still forbidden.

Reject if:

- `password_hash` empty / not a PHC string
- algorithm prefix does not match configured algorithm:

| algorithm | accepted prefix |
|---|---|
| argon2id | `$argon2id$` |
| bcrypt | `$2` |
| scrypt | `$scrypt$` |
| pbkdf2 | `$pbkdf2` |

Do not re-hash. Store `password_hash` as `PasswordCredential.secret`.

Success body (no secrets):

```json
{ "account_id": "acc_…", "email": "alice@example.org", "account_type": "instant" }
```

No `password`, no `dclogin_link`.

Plaintext `password` in the body is rejected (`400` `invalid_password`).

`validate_password` on plaintext is removed from these handlers. Strength is not enforceable on a hash. Document that as accepted.

Error: `DeltaChatError::InvalidPasswordHash` → `400` `invalid_password_hash`. `DeltaChatError::EndpointsNotConfigured` → `400` `endpoints_not_configured`. `DeltaChatError::UnsupportedHashAlgorithm` is not needed on POST (wrong prefix is `invalid_password_hash`).

---

## 8. SPA (TypeScript)

Frontend is TypeScript (`*.ts` / `*.tsx`). New tests are `*.test.ts`, not `.js`. `npm test` may keep `node --test` as long as it loads `.ts`.

One fetch: `GET /api/v1/config`.

Flow:

1. Read domain, endpoints, `certificate_checks`, `password_hash_algorithm`, altcha.
2. If hash algorithm is not one of the four WASM-supported names, show error and do not signup. No silent fallback.
3. Generate username + plaintext password in memory.
4. Hash with advertised algorithm (PHC string).
5. `buildDcloginUri({ email, password, imapHost, imapPort, imapSecurity, smtpHost, smtpPort, smtpSecurity, certificateChecks })` — every field required; throw if any missing. No `mail.{domain}` default, no `ic=3`.
6. POST `{ username, password_hash, altcha_payload? }`.
7. On 2xx, show QR from the in-memory URI.

WASM hasher: add `hash-wasm` (already-capable PHC output for argon2id, bcrypt, scrypt, pbkdf2). One small `utils/password-hash.ts` wrapping it. No extra config object.

Mock service: same contract. Mock config includes endpoints + algorithm. Mock create returns `{ account_id, email, account_type }` only.

---

## 9. No backend generators

Delete from `crates/deltachat`:

- `generate_instant_credentials` (username + password)
- Production use of `build_dclogin_uri`. HTTP handlers must not build QR URIs. Prefer deleting `dclogin.rs` once handlers and e2e stop calling it. URI tests live in the SPA (`dclogin.ts` / `dclogin.test.ts`).

Keep only: `CertificateChecks` + `EndpointSecurity` on settings (needed for `/api/v1/config`), username **validation** (`validate_username`, `validate_instant_username`).

Invalid `ic` / security strings fail at admin `ObjectImpl::validate`, not at URI build.

---

## 10. Testing (TDD)

Rust:

- Hash accept/reject by prefix vs `PasswordHashAlgorithm`.
- Instant/custom handlers store the given hash, do not return `dclogin_link`, do not generate `dc_` or passwords.
- Config JSON includes `password_hash_algorithm` from `server.core.network.security` and admin endpoints/`ic`.
- Pickle v2 still loads; v3 round-trips endpoints.

TypeScript (`signup-relay/frontend`, `*.test.ts`):

- `buildDcloginUri` throws without endpoints/`ic`.
- `password-hash.ts` produces a string starting with the expected prefix.
- Onboarding does not read `dclogin_link` from the response.
- Instant username `dc_` + 12 hex is generated only in the SPA.

## 10.1 Review gate (every task)

A task is not done until **two agents** both pass, after tests are green:

1. **Security** — secrets not logged/returned, no plaintext password in POST, no hardcoded `ic`/hosts/hash, prefix check cannot be bypassed, no extra public JMAP.
2. **Language + clean code** — Rust/TypeScript idioms for that layer; DRY/KISS; no extra files or fallbacks.

Fail either → fix before the next task. Do not batch reviews at the end.

---

## 11. Non-goals

- Client-side hashing as a substitute for TLS.
- Password strength on the server for these routes.
- Second public config URL.
- Hardcoded Argon2id anywhere new secrets are created.

---

## 12. Success

Admin can set IMAP/SMTP host/port/security and `ic`. Changing Authentication hash algorithm changes `/api/v1/config` and what POST accepts. SPA builds the QR. Server never sees plaintext. No `ic=3` or `Argon2id` literals in DeltaChat account creation.
