# Design: DeltaChat Registration Prefixes and Phishing Defenses (Restricted Usernames)

**Document ID:** `SPEC-2026-10-17-USERNAME-RESTRICTION`  
**Status:** In Review  
**Date:** 2026-10-17  
**Target:** `crates/deltachat`, `crates/registry`, `resources/schema`  
**Principles:** Clean Code, DRY, KISS, Full Operator Sovereignty (admin can configure any domain; all username rules editable in WebUI).

---

## 1. Executive Summary & Objective

In open and semi-open registration systems (such as DeltaChat onboarding via Stalwart), malicious actors attempt to register privileged, misleading, or deceptive accounts to conduct phishing, authority impersonation, and social engineering attacks.

This specification defines:
1. **Configurable Account Prefixes:** Separate toggleable prefixes for Instant (1-click random) accounts and Custom accounts, fully manageable in the DeltaChat Admin WebUI and propagated to the frontend via `/api/v1/config`.
2. **Dynamic Username Blacklist & Phishing Defense:** An editable, removable list of restricted usernames and wildcard patterns stored in the DeltaChat schema with sensible security defaults covering system roles, RFC 2142 standards, and phishing lures.
3. **Admin Domain Sovereignty:** The server administrator has complete authority to configure any domain they want (including internal, local, subdomains, or any custom domain). The system imposes zero programmatic restrictions on administrator domain creation; restrictions apply strictly and exclusively to end-user account registration (usernames, prefixes, and blacklists).
4. **R&D Industry Standards:** Direct mapping to RFC 2142, RFC 5321, RFC 5322, Unicode TR39, NIST SP 800-63B, and OWASP ASVS v4.0.

---

## 2. Current State & Deficiencies

| Component | Current Implementation | Defect / Vulnerability |
|---|---|---|
| `crates/deltachat/src/handlers/accounts.rs` | `const RESERVED_NAMES: &[&str]` (19 static names). | Hardcoded in Rust. Operator cannot add company VIPs, custom brands, or remove names if needed. |
| `crates/deltachat/src/handlers/accounts.rs` | `u.starts_with("dc_")` hardcoded for instant accounts. | Cannot be changed or disabled; breaks deployments using custom prefixes or no prefix. |
| `crates/deltachat/src/config.rs` | `DeltaChatSettings` lacks prefix and blacklist fields. | Settings are not persisted in registry storage. |
| `resources/schema/schema.json.gz` | `x:DeltaChat/DeltaChatGeneral` only has service toggles. | No UI inputs for account prefixes or username restrictions. |
| `crates/deltachat/src/handlers/system.rs` | `/api/v1/config` returns `domain`, `endpoints`, `altcha`. | Frontend SPA cannot know registration prefix policies dynamically. |

---

## 3. Architecture & Data Flow

```
                      +---------------------------------------+
                      |         Stalwart Admin WebUI          |
                      | (x:DeltaChat/DeltaChatGeneral form)   |
                      +-------------------+-------------------+
                                          |
                                    JMAP Set / Patch
                                          v
                      +---------------------------------------+
                      |       DeltaChat Registry Schema       |
                      | - instant_prefix_enabled (bool)       |
                      | - instant_prefix (string)             |
                      | - custom_prefix_enabled (bool)        |
                      | - custom_prefix (string)              |
                      | - username_blacklist (List<String>)   |
                      +-------------------+-------------------+
                                          |
                      +-------------------+-------------------+
                      |                                       |
                      v                                       v
          GET /api/v1/config                 POST /api/v1/accounts/*
                      |                                       |
                      v                                       v
          +-----------------------+              +---------------------------+
          |     Frontend SPA      |              |   Registration Pipeline   |
          | - Renders form rules  |              | 1. Syntax & Length Guard  |
          | - Generates random    |              | 2. Prefix Rule Validator  |
          |   dc_... username     |              | 3. Blacklist Wildcard     |
          +-----------------------+              |    Matcher                |
                                                 +---------------------------+
```

---

## 4. Schema & Configuration Specification

### 4.1. Registry Struct (`crates/registry/src/schema/structs.rs`)

Add the following fields to `pub struct DeltaChat`:

```rust
#[serde(rename = "instantPrefixEnabled")]
pub instant_prefix_enabled: bool,

#[serde(rename = "instantPrefix", deserialize_with = "deserialize_null_default")]
pub instant_prefix: String,

#[serde(rename = "customPrefixEnabled")]
pub custom_prefix_enabled: bool,

#[serde(rename = "customPrefix", deserialize_with = "deserialize_null_default")]
pub custom_prefix: String,

#[serde(rename = "usernameBlacklist")]
pub username_blacklist: List<String>,
```

### 4.2. Default Settings & Defaults (`crates/registry/src/schema/structs_impl.rs`)

```rust
impl Default for DeltaChat {
    fn default() -> Self {
        Self {
            // ... existing fields ...
            instant_prefix_enabled: true,
            instant_prefix: "dc_".to_string(),
            custom_prefix_enabled: false,
            custom_prefix: String::new(),
            username_blacklist: default_username_blacklist(),
        }
    }
}
```

### 4.3. DeltaChat Runtime Settings (`crates/deltachat/src/config.rs`)

Mirror the schema fields in `DeltaChatSettings`:
- `pub instant_prefix_enabled: bool` (default: `true`)
- `pub instant_prefix: String` (default: `"dc_"`)
- `pub custom_prefix_enabled: bool` (default: `false`)
- `pub custom_prefix: String` (default: `""`)
- `pub username_blacklist: Vec<String>` (default: preloaded security catalog)

### 4.4. WebUI Form Specification (`resources/schema/schema.json.gz`)

In `x:DeltaChat/DeltaChatGeneral`, organize settings into two dedicated UI sections using standard Stalwart toggle and input widgets:

#### Section A: Account Prefixes
- **Enforce Instant Account Prefix** (`instantPrefixEnabled`): `boolean` switch (Default: `true`).
- **Instant Account Prefix** (`instantPrefix`): `string` input (Default: `"dc_"`). Visible/effective when `instantPrefixEnabled` is `true`.
- **Enforce Custom Account Prefix** (`customPrefixEnabled`): `boolean` switch (Default: `false`).
- **Custom Account Prefix** (`customPrefix`): `string` input (Default: `""`). Visible/effective when `customPrefixEnabled` is `true`.

#### Section B: Username Restriction Policy
- **Restricted Usernames & Wildcards** (`usernameBlacklist`): `list` of `string` tags/chips. Admins can view, append, edit, or delete any pattern (e.g. `*admin*`, `support-*`, `billing`).

---

## 5. Registration Validation Engine

Validation occurs in `crates/deltachat/src/handlers/accounts.rs`.

### 5.1. Character & Syntax Rules (Boundary Defense)
1. **Length:** Minimum 3 characters, maximum 32 characters.
2. **Character Set:** Strict ASCII `[a-z0-9._-]`.
   - **Security Benefit:** By disallowing non-ASCII characters at registration, Unicode homoglyph attacks (e.g., Cyrillic `а` spoofing Latin `a`) and zero-width spaces are eliminated at zero runtime cost.
3. **Punctuation Rules:** Cannot start with a dot, end with a dot, or contain consecutive dots (`..`).

### 5.2. Prefix Enforcement Logic

#### Instant Accounts (`validate_instant_username`)
- If `instant_prefix_enabled` is `true`:
  - Must start with `instant_prefix`.
  - Suffix after `instant_prefix` must be exactly 12 hexadecimal characters (`[0-9a-f]`).
- If `instant_prefix_enabled` is `false`:
  - Username must be between 12 and 16 hexadecimal characters (`[0-9a-f]`).

#### Custom Accounts (`validate_custom_username`)
- **Instant Collision Guard:**
  - If `instant_prefix_enabled` is `true` AND `instant_prefix` is non-empty:
    - If username starts with `instant_prefix`, return `DeltaChatError::InvalidUsername("Username prefix '{instant_prefix}' is reserved for instant accounts")`.
- **Custom Prefix Requirement:**
  - If `custom_prefix_enabled` is `true` AND `custom_prefix` is non-empty:
    - If username does NOT start with `custom_prefix`, return `DeltaChatError::InvalidUsername("Username must start with prefix '{custom_prefix}'")`.

### 5.3. Blacklist & Wildcard Matcher
Custom usernames are checked against `settings.username_blacklist`:
- Matching is case-insensitive.
- If pattern starts and ends with `*` (e.g., `*admin*`): checks `username.contains("admin")`.
- If pattern ends with `*` (e.g., `support-*`): checks `username.starts_with("support-")`.
- If pattern starts with `*` (e.g., `*-bot`): checks `username.ends_with("-bot")`.
- Otherwise: exact equality match (`username == pattern`).
- If matched: return `DeltaChatError::InvalidUsername("Username is reserved or restricted")`.

---

## 6. Complete Catalog of Restricted Usernames (Default Seed)

The following baseline is preloaded into `default_username_blacklist()`:

### 6.1. System & Administrative Authorities
Prevents impersonation of server administrators and elevated roles:
```
admin
administrator
superadmin
sysadmin
root
master
owner
operator
moderator
mod
staff
team
```

### 6.2. RFC 2142 Internet Standard Mailboxes
Mandatory mailboxes required by Internet standards for network and security operations:
```
postmaster
hostmaster
webmaster
abuse
security
noc
mailer-daemon
nobody
```

### 6.3. Trust, Security & Phishing Lures
Keywords frequently abused in social engineering, credential harvesting, and fake alerts:
```
support
help
helpdesk
service
services
billing
account
accounts
verify
verification
security-alert
official
login
auth
authentication
password
recovery
compliance
legal
contact
sales
info
notify
notification
notifications
alerts
system-alert
```

### 6.4. Infrastructure, Protocols & Network Daemon Names
Prevents collision with mail server protocols, DNS roles, and discovery mechanisms:
```
daemon
system
server
relay
mail
mx
mx1
mx2
smtp
smtps
imap
imaps
pop
pop3
pop3s
autodiscover
autoconfig
mta-sts
dmarc
dkim
spf
dns
ns
ns1
ns2
gateway
router
proxy
internal
api
dev
test
stage
staging
prod
production
```

### 6.5. Impersonation & Brand Protection
Prevents impersonating core software platforms:
```
deltachat
delta-chat
stalwart
stalw.art
chatchi
bot
robot
null
undefined
anonymous
guest
public
```

### 6.6. High-Risk Leetspeak & Typo Aliases
Direct protections against common character substitutions:
```
adm1n
admln
r00t
supp0rt
s3curity
0fficial
```

### 6.7. Default Wildcards
Broad substring restrictions for persistent security:
```
*admin*
*support*
*system*
*helpdesk*
```

---

## 7. Domain Architecture: Administrator Sovereignty & Best-Practice Reference

### 7.1. Full Administrator Sovereignty
Stalwart does **not** restrict or block administrators from creating or configuring any domain of their choice. Administrators have full autonomy to host:
- Public root and subdomains (`chat.example.com`, `example.org`).
- Local or test environments (`localhost`, `.test`, `.lan`, `.internal`).
- Multi-tenant or private organizational namespaces.

**All restrictions in this specification apply strictly and exclusively to end-user account registration (usernames, prefixes, and username blacklists).**

### 7.2. Administrator Best-Practice Reference (Informational)
For administrators planning domain architectures, the following industry best practices are recommended to avoid user confusion and deliverability problems:

1. **Avoid RFC 2606 / RFC 6761 Special-Use Names in Production:**
   - Domains like `.test`, `.invalid`, `.example`, and `localhost` are non-routable on the public internet. They should only be used in isolated development or testing environments.
2. **Avoid Collisions with Public Mail Providers:**
   - Hosting domains that match major public providers (e.g. `gmail.com`, `outlook.com`, `icloud.com`) within a private network causes local delivery interception, breaking outbound communication to actual users of those services.
3. **Dedicated Subdomains for Chat/Messaging:**
   - Using dedicated subdomains (such as `chat.domain.com` or `mail.domain.com`) separates IMAP/SMTP messaging infrastructure and reputation from corporate apex domains.
4. **Punycode / IDN Awareness:**
   - Internationalized Domain Names (IDNs) should be carefully audited by operators to ensure they do not visually mimic established brand domains.

---

## 8. Public Discovery API Contract (`GET /api/v1/config`)

The endpoint `GET /api/v1/config` (served by `crates/deltachat/src/handlers/system.rs`) is expanded so client SPAs can adapt their registration wizards dynamically:

```json
{
  "domain": "example.org",
  "registration_open": true,
  "instant_accounts_enabled": true,
  "custom_accounts_enabled": true,
  "instant_prefix_enabled": true,
  "instant_prefix": "dc_",
  "custom_prefix_enabled": false,
  "custom_prefix": "",
  "endpoints": {
    "imap": { "host": "mail.example.org", "port": 993, "security": "ssl" },
    "smtp": { "host": "mail.example.org", "port": 465, "security": "ssl" }
  },
  "altcha": {
    "required": false,
    "max_number": 100000,
    "challenge": null
  },
  "password_hash_algorithm": "argon2id"
}
```

---

## 9. R&D Best Practices and Industry Standards

This design adheres to international security and email infrastructure standards:

1. **RFC 2142 (Mailbox Names for Common Services, Roles and Functions):**
   - Mandates well-known mailbox names (`postmaster`, `abuse`, `noc`, `security`, `hostmaster`, `webmaster`).
   - Reserving these addresses for legitimate administrative personnel prevents unauthorized users from receiving critical network notifications or certificate authority (CA) verification emails.

2. **RFC 5321 & RFC 5322 (SMTP & Internet Message Format):**
   - Specifies valid local-part syntax and forbids consecutive or boundary periods.

3. **RFC 2606 & RFC 6761 (Special-Use Domain Names):**
   - Guarantees that internal testing, invalid, and loopback domains are rejected at registration boundaries.

4. **NIST SP 800-63B (Digital Identity Guidelines: Authentication and Lifecycle Management):**
   - Section 5.1: Account onboarding must restrict impersonation of system functions, administrators, and authoritative entities.

5. **OWASP Application Security Verification Standard (ASVS) v4.0:**
   - **V2.1.2:** Verify that user registration prevents username spoofing and reserves critical administrative account names.
   - **V2.1.3:** Verify that account creation controls prevent automated account harvesting and denial-of-service through input bounds.

6. **Unicode Technical Report #39 (Unicode Security Mechanisms):**
   - Recommends restriction levels for identifier profiles. Stalwart achieves *Highly Restrictive* compliance by constraining registration usernames to ASCII `[a-z0-9._-]`, neutralizing whole-script and mixed-script homograph attacks (e.g. Cyrillic `а` vs Latin `a`).

7. **Zero-Downtime Operator Sovereignty:**
   - All rules and prefixes reside in the schema.
   - Operators can customize lists without recompilation, code patches, or service interruption.

---

## 10. Verification & Test Plan

1. **Unit Tests (`crates/deltachat/src/handlers/accounts.rs`):**
   - Instant accounts:
     - Enabled prefix `"dc_"`: `dc_0123456789ab` passes; `xx_0123456789ab` fails; `dc_short` fails.
     - Disabled prefix: `0123456789ab` (12 hex chars) passes.
   - Custom accounts:
     - Disallowed instant prefix: username starting with `"dc_"` is rejected when instant prefix is enabled.
     - Enforced custom prefix: when `custom_prefix_enabled` is `true` with `"usr_"`, `usr_alice` passes; `alice` fails.
     - Blacklist matching: exact match (`admin`, `support`), wildcard match (`*admin*`, `support-*`, `*-bot`).
     - Normal usernames (`rezishon0`, `user123`, `alex99`) are allowed and never corrupted.
2. **API Tests (`crates/deltachat/tests/e2e_tests.rs`):**
   - `GET /api/v1/config` returns `instant_prefix_enabled`, `instant_prefix`, `custom_prefix_enabled`, `custom_prefix`.
3. **Persistence Tests (`crates/registry`):**
   - Verify serialization, unpickling, and default generation for the new fields in `struct DeltaChat`.
