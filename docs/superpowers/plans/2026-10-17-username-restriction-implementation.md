# DeltaChat Registration Prefixes and Phishing Defenses Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement configurable account prefixes (instant & custom) with on/off toggles, a dynamic username blacklist supporting exact and wildcard matching with safe default seeds, and expose prefix policies via `GET /api/v1/config`.

**Architecture:** Add 5 schema fields to `DeltaChat` in `crates/registry` using `Map<String>` for `username_blacklist` with Pickle v4 support and WebUI forms in `resources/schema/schema.json.gz`. Wire these fields into `DeltaChatSettings` in `crates/deltachat/src/config.rs`. Update `GET /api/v1/config` to return prefix settings. Update `crates/deltachat/src/handlers/accounts.rs` to validate instant and custom usernames against configured prefix rules and blacklist patterns using a safe, zero-copy matcher.

**Tech Stack:** Rust 2024, Actix/Stalwart HTTP, Serde, JMAP registry, gzip/JSON schema.

**Spec:** `docs/superpowers/specs/2026-10-17-username-domain-restriction-design.md`

## Global Constraints

- Full Operator Sovereignty: No hardcoded uneditable lists; all restrictions are configurable in the WebUI.
- Zero Domain Creation Restrictions: Administrators are never restricted from creating any domain.
- Clean Code, DRY, and KISS: Minimal code diffs, zero runtime overhead, standard library and existing patterns.
- Pickle v4: Backward-compatible deserialization for v0, v1, v2, and v3 blobs.
- Character syntax: Usernames restricted to ASCII `[a-z0-9._-]` (3..=32 chars).
- Safe Matchers: Degenerate wildcards (`*`, `**`, `""`) never panic and never trigger universal registration lockouts.

---

### Task 1: Schema Properties and Data Structures (`crates/registry`)

**Files:**
- Modify: `crates/registry/src/schema/properties.rs:955-965`
- Modify: `crates/registry/src/schema/properties_impl.rs`
- Modify: `crates/registry/src/schema/structs.rs:6355-6365`
- Modify: `crates/registry/src/schema/structs_impl.rs:47650-47880`
- Test: `crates/registry/src/schema/structs_impl.rs:deltachat_pickle_tests`

**Interfaces:**
- Consumes: `Property` enum, `Pickle`, `DeltaChat` struct
- Produces:
  - `Property::InstantPrefixEnabled` (956)
  - `Property::InstantPrefix` (957)
  - `Property::CustomPrefixEnabled` (958)
  - `Property::CustomPrefix` (959)
  - `Property::UsernameBlacklist` (960)
  - `Property::COUNT = 961`
  - `pub const DEFAULT_USERNAME_BLACKLIST: &[&str]`
  - New fields in `struct DeltaChat`:
    - `instant_prefix_enabled: bool` (default: `true`)
    - `instant_prefix: String` (default: `"dc_"`)
    - `custom_prefix_enabled: bool` (default: `false`)
    - `custom_prefix: String` (default: `""`)
    - `username_blacklist: Map<String>` (default: preloaded security catalog)

- [ ] **Step 1: Write the failing tests in `crates/registry/src/schema/structs_impl.rs`**

```rust
#[test]
fn roundtrip_v4_prefixes_and_blacklist() {
    let orig = DeltaChat {
        instant_prefix_enabled: true,
        instant_prefix: "dc_".into(),
        custom_prefix_enabled: true,
        custom_prefix: "usr_".into(),
        username_blacklist: Map::new(vec![
            "admin".to_string(),
            "*support*".to_string(),
        ]),
        ..Default::default()
    };
    let bytes = orig.to_pickled_vec();
    let mut stream = PickledStream::new(&bytes).unwrap();
    let unpickled = DeltaChat::unpickle(&mut stream).unwrap();
    assert_eq!(orig, unpickled);
}

#[test]
fn unpickle_v3_leaves_v4_defaults() {
    let mut bytes = vec![3u8];
    true.pickle(&mut bytes);                           // enabled
    true.pickle(&mut bytes);                           // registration_open
    true.pickle(&mut bytes);                           // instant_accounts_enabled
    true.pickle(&mut bytes);                           // custom_accounts_enabled
    None::<String>.pickle(&mut bytes);                 // frontend_path
    Id::from(7u32).pickle(&mut bytes);                 // domain_id
    Map::<Id>::default().pickle(&mut bytes);           // allowed_domains
    false.pickle(&mut bytes);                          // altcha_required
    100_000u64.pickle(&mut bytes);                     // altcha_max_number
    String::new().pickle(&mut bytes);                  // altcha_hmac_secret
    "imap.example.org".to_string().pickle(&mut bytes); // imap_host
    993u64.pickle(&mut bytes);                         // imap_port
    "ssl".to_string().pickle(&mut bytes);              // imap_security
    "smtp.example.org".to_string().pickle(&mut bytes); // smtp_host
    465u64.pickle(&mut bytes);                         // smtp_port
    "ssl".to_string().pickle(&mut bytes);              // smtp_security
    "3".to_string().pickle(&mut bytes);                // certificate_checks

    let mut stream = PickledStream::new(&bytes).unwrap();
    let obj = DeltaChat::unpickle(&mut stream).expect("v3 blob unpickles into v4 struct");
    assert!(obj.instant_prefix_enabled);
    assert_eq!(obj.instant_prefix, "dc_");
    assert!(!obj.custom_prefix_enabled);
    assert_eq!(obj.custom_prefix, "");
    assert!(!obj.username_blacklist.is_empty());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p registry roundtrip_v4_prefixes_and_blacklist`
Expected: FAIL compilation with unknown fields `instant_prefix_enabled`, etc.

- [ ] **Step 3: Implement Properties, Struct, Pickle v4, and Default Catalog**

In `crates/registry/src/schema/properties.rs`:
```rust
    InstantPrefixEnabled = 956,
    InstantPrefix = 957,
    CustomPrefixEnabled = 958,
    CustomPrefix = 959,
    UsernameBlacklist = 960,
```

In `crates/registry/src/schema/properties_impl.rs`:
- Update `const COUNT: usize = 961;`
- In `Property::parse`: Add entries for `b"instantPrefixEnabled"`, `b"instantPrefix"`, `b"customPrefixEnabled"`, `b"customPrefix"`, `b"usernameBlacklist"`.
- In `Property::as_str`: Add matches for the 5 properties.
- In `Property::from_id`: Map 956..=960 to their enum variants.

In `crates/registry/src/schema/structs.rs`:
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
    pub username_blacklist: Map<String>,
```

In `crates/registry/src/schema/structs_impl.rs`:
- Define `pub const DEFAULT_USERNAME_BLACKLIST: &[&str] = &[ ... ];` containing the seed list from Spec Section 6.
- Bump `ObjectImpl::VERSION` for `DeltaChat` from `3` to `4`.
- In `ObjectImpl::validate for DeltaChat`:
  - Limit `self.username_blacklist.len() <= 1000`.
  - Validate `self.instant_prefix.len() <= 16` and `self.custom_prefix.len() <= 16`.
  - Validate prefixes contain only `[a-z0-9._-]`.
  - Check that if `self.instant_prefix_enabled && self.custom_prefix_enabled && !self.instant_prefix.is_empty()`, `self.instant_prefix != self.custom_prefix`.
- In `Pickle::pickle`, append the 5 fields.
- In `Pickle::unpickle`:
  ```rust
  if stream.version() >= 4 {
      this.instant_prefix_enabled = Pickle::unpickle(stream)?;
      this.instant_prefix = Pickle::unpickle(stream)?;
      this.custom_prefix_enabled = Pickle::unpickle(stream)?;
      this.custom_prefix = Pickle::unpickle(stream)?;
      this.username_blacklist = Pickle::unpickle(stream)?;
  }
  ```
- In `IntoValue for DeltaChat`:
  - Increase capacity: `jmap_tools::Map::with_capacity(22)`.
  - Insert the 5 new properties.
- In `RegistryJsonPropertyPatch for DeltaChat`:
  - `Some(Property::InstantPrefixEnabled) => self.instant_prefix_enabled.patch(pointer, value),`
  - `Some(Property::InstantPrefix) => patch_empty_ok(&mut self.instant_prefix, pointer, value),`
  - `Some(Property::CustomPrefixEnabled) => self.custom_prefix_enabled.patch(pointer, value),`
  - `Some(Property::CustomPrefix) => patch_empty_ok(&mut self.custom_prefix, pointer, value),`
  - `Some(Property::UsernameBlacklist) => self.username_blacklist.patch(pointer, value),`

- [ ] **Step 4: Run registry tests to verify they pass**

Run: `cargo test -p registry deltachat_pickle_tests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add crates/registry/src/schema/
git commit -m "feat(registry): add DeltaChat account prefixes and username blacklist schema fields"
```

---

### Task 2: WebUI Admin Form & Schema Definition (`resources/schema`)

**Files:**
- Modify: `resources/schema/schema.json.gz`
- Modify: `resources/schema/schema.json.sha256`

**Interfaces:**
- Consumes: Fields defined in Task 1
- Produces: Reactive form fields and inputs in Stalwart Admin WebUI under `x:DeltaChat/DeltaChatGeneral`.

- [ ] **Step 1: Extract and inspect `schema.json`**

```bash
python3 -c "import gzip, json; open('/tmp/schema.json', 'w').write(json.dumps(json.load(gzip.open('resources/schema/schema.json.gz')), indent=2))"
```

- [ ] **Step 2: Add fields and form sections to `schema.json`**

In `data['fields']['x:DeltaChat']['properties']`:
```json
"instantPrefixEnabled": {
  "description": "Enforce prefix requirement on instant accounts",
  "type": { "type": "boolean" },
  "update": "mutable"
},
"instantPrefix": {
  "description": "Prefix prepended to instant account usernames (default dc_)",
  "type": { "type": "string", "format": "string" },
  "update": "mutable"
},
"customPrefixEnabled": {
  "description": "Enforce prefix requirement on custom accounts",
  "type": { "type": "boolean" },
  "update": "mutable"
},
"customPrefix": {
  "description": "Prefix required for custom account usernames",
  "type": { "type": "string", "format": "string" },
  "update": "mutable"
},
"usernameBlacklist": {
  "description": "Restricted usernames and wildcard patterns (e.g. *admin*, support-*, billing)",
  "type": { "type": "map", "values": { "type": "boolean" } },
  "update": "mutable"
}
```

In `data['forms']['x:DeltaChat/DeltaChatGeneral']['sections']`:
- Append Section `"Account Prefixes"`:
  - `instantPrefixEnabled` (label: "Enforce Instant Account Prefix")
  - `instantPrefix` (label: "Instant Account Prefix")
  - `customPrefixEnabled` (label: "Enforce Custom Account Prefix")
  - `customPrefix` (label: "Custom Account Prefix")
- Append Section `"Username Restriction Policy"`:
  - `usernameBlacklist` (label: "Restricted Usernames & Wildcards")

- [ ] **Step 3: Compress deterministically and synchronize checksum**

```bash
gzip -n -9 -c /tmp/schema.json > resources/schema/schema.json.gz
sha256sum resources/schema/schema.json.gz | awk '{print $1}' > resources/schema/schema.json.sha256
```

- [ ] **Step 4: Verify schema loads without errors**

Run: `cargo test -p http`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add resources/schema/schema.json.gz resources/schema/schema.json.sha256
git commit -m "feat(webui): add account prefixes and username blacklist to DeltaChat form"
```

---

### Task 3: DeltaChat Settings Struct & Configuration (`crates/deltachat`)

**Files:**
- Modify: `crates/deltachat/src/config.rs`
- Test: `crates/deltachat/src/config.rs:tests`

**Interfaces:**
- Consumes: `registry::schema::structs::DeltaChat`, `DEFAULT_USERNAME_BLACKLIST`
- Produces:
  - `DeltaChatSettings` with `instant_prefix_enabled`, `instant_prefix`, `custom_prefix_enabled`, `custom_prefix`, `username_blacklist`.
  - `From<registry::schema::structs::DeltaChat> for DeltaChatSettings`.

- [ ] **Step 1: Write unit tests in `crates/deltachat/src/config.rs`**

```rust
#[test]
fn test_settings_from_registry_prefixes_and_blacklist() {
    let mut reg = registry::schema::structs::DeltaChat::default();
    reg.instant_prefix_enabled = true;
    reg.instant_prefix = "custom_dc_".into();
    reg.custom_prefix_enabled = true;
    reg.custom_prefix = "usr_".into();
    reg.username_blacklist = registry::types::map::Map::new(vec!["baduser".to_string()]);

    let settings = DeltaChatSettings::from(reg);
    assert!(settings.instant_prefix_enabled);
    assert_eq!(settings.instant_prefix, "custom_dc_");
    assert!(settings.custom_prefix_enabled);
    assert_eq!(settings.custom_prefix, "usr_");
    assert_eq!(settings.username_blacklist, vec!["baduser"]);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p deltachat test_settings_from_registry_prefixes_and_blacklist`
Expected: FAIL compilation with missing fields on `DeltaChatSettings`.

- [ ] **Step 3: Update `DeltaChatSettings` and conversion**

In `crates/deltachat/src/config.rs`:
- Add fields to `DeltaChatSettings`:
  ```rust
  pub instant_prefix_enabled: bool,
  pub instant_prefix: String,
  pub custom_prefix_enabled: bool,
  pub custom_prefix: String,
  pub username_blacklist: Vec<String>,
  ```
- In `Default for DeltaChatSettings`:
  ```rust
  instant_prefix_enabled: true,
  instant_prefix: "dc_".into(),
  custom_prefix_enabled: false,
  custom_prefix: String::new(),
  username_blacklist: registry::schema::structs_impl::DEFAULT_USERNAME_BLACKLIST
      .iter()
      .map(|s| s.to_string())
      .collect(),
  ```
- In `From<registry::schema::structs::DeltaChat> for DeltaChatSettings`:
  Map the new fields, normalizing blacklist strings to lowercase once on load:
  ```rust
  instant_prefix_enabled: c.instant_prefix_enabled,
  instant_prefix: c.instant_prefix,
  custom_prefix_enabled: c.custom_prefix_enabled,
  custom_prefix: c.custom_prefix,
  username_blacklist: c.username_blacklist.into_inner().into_iter().map(|s| s.to_ascii_lowercase()).collect(),
  ```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p deltachat test_settings_from_registry_prefixes_and_blacklist`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add crates/deltachat/src/config.rs
git commit -m "feat(deltachat): wire account prefixes and username blacklist into DeltaChatSettings"
```

---

### Task 4: Public Config Discovery API (`GET /api/v1/config`)

**Files:**
- Modify: `crates/deltachat/src/models.rs:ConfigDiscoveryResponse`
- Modify: `crates/deltachat/src/handlers/system.rs:handle_config`
- Test: `crates/deltachat/src/handlers/system.rs:tests`

**Interfaces:**
- Consumes: `DeltaChatSettings`
- Produces:
  - `ConfigDiscoveryResponse` serialized with:
    - `instant_prefix_enabled: bool`
    - `instant_prefix: String`
    - `custom_prefix_enabled: bool`
    - `custom_prefix: String`

- [ ] **Step 1: Write unit test in `crates/deltachat/src/handlers/system.rs`**

```rust
#[test]
fn config_includes_prefix_settings() {
    let mut settings = DeltaChatSettings::default();
    settings.instant_prefix_enabled = true;
    settings.instant_prefix = "chat_".into();
    settings.custom_prefix_enabled = true;
    settings.custom_prefix = "user_".into();

    let engine = AltchaEngine::new(b"secret".to_vec(), 1000);
    let resp = handle_config(
        &settings,
        &engine,
        "example.org".into(),
        endpoints_from_settings(&settings).unwrap(),
        "argon2id",
    ).unwrap();

    assert!(resp.instant_prefix_enabled);
    assert_eq!(resp.instant_prefix, "chat_");
    assert!(resp.custom_prefix_enabled);
    assert_eq!(resp.custom_prefix, "user_");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p deltachat config_includes_prefix_settings`
Expected: FAIL with unknown fields on `ConfigDiscoveryResponse`.

- [ ] **Step 3: Update `ConfigDiscoveryResponse` and `handle_config`**

In `crates/deltachat/src/models.rs`:
Add fields to `ConfigDiscoveryResponse`:
```rust
    pub instant_prefix_enabled: bool,
    pub instant_prefix: String,
    pub custom_prefix_enabled: bool,
    pub custom_prefix: String,
```
In `crates/deltachat/src/handlers/system.rs`:
Map fields from `settings` in `handle_config`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p deltachat config_includes_prefix_settings`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add crates/deltachat/src/models.rs crates/deltachat/src/handlers/system.rs
git commit -m "feat(deltachat): advertise instant and custom prefixes in /api/v1/config"
```

---

### Task 5: Registration Validation Engine (`crates/deltachat/src/handlers/accounts.rs`)

**Files:**
- Modify: `crates/deltachat/src/handlers/accounts.rs`
- Test: `crates/deltachat/src/handlers/accounts.rs:tests`

**Interfaces:**
- Consumes: `DeltaChatSettings`, username string
- Produces:
  - `validate_username(&req.username, settings: &DeltaChatSettings) -> Result<(), DeltaChatError>`
  - `validate_instant_username(&req.username, settings: &DeltaChatSettings) -> Result<(), DeltaChatError>`
  - `matches_blacklist(username: &str, blacklist: &[String]) -> bool`

- [ ] **Step 1: Write comprehensive unit tests in `crates/deltachat/src/handlers/accounts.rs`**

```rust
#[test]
fn test_instant_username_with_configurable_prefix() {
    let mut settings = DeltaChatSettings::default();
    settings.instant_prefix_enabled = true;
    settings.instant_prefix = "dc_".into();
    assert!(validate_instant_username("dc_0123456789ab", &settings).is_ok());
    assert!(validate_instant_username("xx_0123456789ab", &settings).is_err());
    assert!(validate_instant_username("dc_short", &settings).is_err());

    // Custom prefix
    settings.instant_prefix = "bot_".into();
    assert!(validate_instant_username("bot_0123456789ab", &settings).is_ok());
    assert!(validate_instant_username("dc_0123456789ab", &settings).is_err());

    // Disabled prefix (12-16 hex chars)
    settings.instant_prefix_enabled = false;
    assert!(validate_instant_username("0123456789ab", &settings).is_ok());
    assert!(validate_instant_username("0123456789abcdef", &settings).is_ok());
    assert!(validate_instant_username("0123456789", &settings).is_err()); // Too short
    assert!(validate_instant_username("not_hex_chars!", &settings).is_err());

    // Instant accounts cannot use blacklisted names
    settings.username_blacklist = vec!["bot_0123456789ab".into()];
    assert!(validate_instant_username("bot_0123456789ab", &settings).is_err());
}

#[test]
fn test_custom_username_prefix_and_blacklist() {
    let mut settings = DeltaChatSettings::default();
    settings.instant_prefix_enabled = true;
    settings.instant_prefix = "dc_".into();
    settings.username_blacklist = vec![
        "admin".into(),
        "*support*".into(),
        "vip_*".into(),
        "*-bot".into(),
        "*".into(), // degenerate wildcard: should be ignored safely
        "".into(),  // empty: should be ignored safely
    ];

    // Disallow instant prefix
    assert!(validate_username("dc_alex", &settings).is_err());

    // Blacklist exact and wildcards
    assert!(validate_username("admin", &settings).is_err());
    assert!(validate_username("tech-support-team", &settings).is_err());
    assert!(validate_username("vip_user", &settings).is_err());
    assert!(validate_username("helper-bot", &settings).is_err());

    // Normal names allowed despite degenerate wildcards in list
    assert!(validate_username("rezishon0", &settings).is_ok());
    assert!(validate_username("alice", &settings).is_ok());

    // Instant namespace collision guard when instant prefix disabled
    settings.instant_prefix_enabled = false;
    assert!(validate_username("0123456789ab", &settings).is_err()); // Hex reserved for instant
    assert!(validate_username("alice_normal", &settings).is_ok());

    // Custom prefix enforced
    settings.custom_prefix_enabled = true;
    settings.custom_prefix = "usr_".into();
    assert!(validate_username("usr_alice", &settings).is_ok());
    assert!(validate_username("alice", &settings).is_err());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p deltachat test_custom_username_prefix_and_blacklist`
Expected: FAIL compilation (signature mismatch).

- [ ] **Step 3: Implement validation logic and delete legacy `RESERVED_NAMES`**

In `crates/deltachat/src/handlers/accounts.rs`:
- Remove `const RESERVED_NAMES: &[&str]`.
- Implement `pub fn matches_blacklist(username: &str, blacklist: &[String]) -> bool`:
  ```rust
  pub fn matches_blacklist(username: &str, blacklist: &[String]) -> bool {
      blacklist.iter().any(|pattern| {
          let pattern = pattern.trim();
          if pattern.is_empty() {
              return false;
          }
          if let Some(inner) = pattern.strip_prefix('*').and_then(|p| p.strip_suffix('*')) {
              !inner.is_empty() && username.contains(inner)
          } else if let Some(prefix) = pattern.strip_suffix('*') {
              !prefix.is_empty() && username.starts_with(prefix)
          } else if let Some(suffix) = pattern.strip_prefix('*') {
              !suffix.is_empty() && username.ends_with(suffix)
          } else {
              username == pattern
          }
      })
  }
  ```
- Implement `pub fn validate_instant_username(username: &str, settings: &DeltaChatSettings) -> Result<(), DeltaChatError>`:
  - Check length 3..=32 chars.
  - Check `matches_blacklist(u, &settings.username_blacklist)`.
  - If `settings.instant_prefix_enabled`: prefix check + 12 hex chars.
  - If disabled: length 12..=16 hex chars.
- Implement `pub fn validate_username(username: &str, settings: &DeltaChatSettings) -> Result<(), DeltaChatError>`:
  - Length 3..=32 chars.
  - Dot checks (no leading, trailing, consecutive).
  - Character set: `[a-z0-9._-]`.
  - Collision check against instant account namespace:
    - If `settings.instant_accounts_enabled`:
      - If `settings.instant_prefix_enabled && !settings.instant_prefix.is_empty()`: reject if `u.starts_with(&settings.instant_prefix.to_ascii_lowercase())`.
      - Else if `(12..=16).contains(&u.len()) && u.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))`: reject reserved hex.
  - Custom prefix check:
    - If `settings.custom_prefix_enabled && !settings.custom_prefix.is_empty()`: reject if `!u.starts_with(&settings.custom_prefix.to_ascii_lowercase())`.
  - Blacklist check:
    - Reject if `matches_blacklist(&u, &settings.username_blacklist)`.
- Update call sites in `handle_instant_account` and `handle_custom_account` to pass `settings`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p deltachat test_custom_username_prefix_and_blacklist`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add crates/deltachat/src/handlers/accounts.rs
git commit -m "feat(deltachat): enforce configurable prefixes and dynamic username blacklist"
```

---

### Task 6: End-to-End Tests and Verification

**Files:**
- Modify: `crates/deltachat/tests/e2e_tests.rs`

**Interfaces:**
- Consumes: All components from Tasks 1-5
- Produces: Passing end-to-end test suite confirming full API functionality.

- [ ] **Step 1: Write E2E test verifying API rejection of blacklisted and invalid prefix custom registrations**

In `crates/deltachat/tests/e2e_tests.rs`:
```rust
#[tokio::test]
async fn test_registration_validation_rejections() {
    let router = DeltaChatRouter::new(None);
    let server = dummy_server();
    let mut settings = DeltaChatSettings::default();
    settings.custom_accounts_enabled = true;
    settings.username_blacklist = vec!["admin".into(), "*support*".into()];

    // 1. Blacklisted username fails at validation before DB write
    let bad_req = serde_json::to_vec(&CustomAccountRequest {
        username: "admin".into(),
        password_hash: "hash".into(),
        altcha_payload: None,
        password: None,
    }).unwrap();
    let err = router.dispatch_api(&settings, &server, "POST", "/api/v1/accounts/custom", Some(&bad_req)).await.unwrap_err();
    assert!(matches!(err, DeltaChatError::InvalidUsername(_)));

    // 2. Wildcard blacklisted username fails
    let bad_req2 = serde_json::to_vec(&CustomAccountRequest {
        username: "tech-support".into(),
        password_hash: "hash".into(),
        altcha_payload: None,
        password: None,
    }).unwrap();
    let err2 = router.dispatch_api(&settings, &server, "POST", "/api/v1/accounts/custom", Some(&bad_req2)).await.unwrap_err();
    assert!(matches!(err2, DeltaChatError::InvalidUsername(_)));
}
```

- [ ] **Step 2: Run test suite**

Run: `cargo test -p deltachat --test e2e_tests`
Expected: PASS

- [ ] **Step 3: Run clippy and formatting checks**

Run: `cargo clippy -p deltachat -p registry --all-targets`
Expected: No errors or warnings.

- [ ] **Step 4: Commit**

```bash
git add crates/deltachat/tests/e2e_tests.rs
git commit -m "test(deltachat): add e2e tests for registration prefixes and username blacklist"
```
