# DeltaChat Relay Page Admin Submenu & /api/v1/config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `Relay Page` sub-menu under `Settings -> DeltaChat` in the Stalwart WebUI for bilingual branding (`platform_name` en/fa, icon, logo), admin contact channels, donation links, and client download links (with server direct download fallback), returning these via `GET /api/v1/config`, and adding inline guidance for `imapSecurity` / `smtpSecurity`.

**Architecture:** Extend existing `ObjectType::DeltaChat = 117` singleton in `crates/registry` with Pickle v5 backward-compatible deserialization and JMAP patch support. Wire into `DeltaChatSettings` in `crates/deltachat/src/config.rs` and serialize in `crates/deltachat/src/handlers/system.rs`. Generate WebUI forms and layouts in `resources/schema/schema.json.gz`.

**Tech Stack:** Rust (`crates/registry`, `crates/deltachat`, `crates/http`), Stalwart WebUI schema engine (`resources/schema/schema.json.gz`), Python 3 (schema manipulation & test verification), serde/serde_json.

**Spec:** `docs/superpowers/specs/2026-10-23-deltachat-relay-page-admin-and-config-design.md`

## Global Constraints

- Cargo crate version stays `0.16.25`. Never put `-rlN` into `Cargo.toml`.
- Crate dependency direction is one-way: `http` -> `deltachat` -> `registry` -> `types`.
- All new registry properties must register in `crates/registry/src/schema/properties.rs` and `properties_impl.rs`.
- Pickle serialization must be strictly sequential; version 4 -> 5 migration must cleanly unpickle existing v0..=v4 blobs using safe defaults.
- Any direct server download or client download/contact/donation item with empty `link` must be filtered out in `/api/v1/config`.
- URL schemes for links must be validated against the allowlist: `https://`, `http://`, `mailto:`, `tg:`, `matrix:`, `bitcoin:`, `monero:`, or safe relative path `/` (not `//` or `/\\`). Reject `javascript:`, data URIs, ASCII control characters, and Unicode Bidi override characters (`U+202A..=U+202E`, `U+2066..=U+2069`).
- Use `patch_empty_ok` for all optional string fields in JMAP patch implementations to allow empty strings and clearing values without JMAP patch rejections.
- Re-compressed schema must use `gzip -n -9` so `schema.json.sha256` is deterministic.

---

### Task 1: Register Properties in Registry Entity Chain

**Files:**
- Modify: `crates/registry/src/schema/properties.rs:960-975`
- Modify: `crates/registry/src/schema/properties_impl.rs:1360-1380,2320-2340,3290-3310`

**Interfaces:**
- Consumes: Existing `Property` enum (`crates/registry/src/schema/properties.rs`)
- Produces: `Property::PlatformNameEn = 961`, `Property::PlatformNameFa = 962`, `Property::PlatformIcon = 963`, `Property::PlatformImageUrl = 964`, `Property::AdminContacts = 965`, `Property::DonationLinks = 966`, `Property::DownloadLinks = 967`, `Property::TitleFa = 968`, `Property::Link = 969`, `Property::Icon = 970`, `Property::ImageUrl = 971`, `Property::IsDirect = 972`. Bump `Property::COUNT = 973`.

- [ ] **Step 1: Write property parse and conversion test in `crates/registry/src/schema/properties_impl.rs`**

Add test to bottom of `crates/registry/src/schema/properties_impl.rs`:
```rust
#[test]
fn test_deltachat_relay_properties_mapping() {
    let cases = [
        ("platformNameEn", Property::PlatformNameEn, 961),
        ("platformNameFa", Property::PlatformNameFa, 962),
        ("platformIcon", Property::PlatformIcon, 963),
        ("platformImageUrl", Property::PlatformImageUrl, 964),
        ("adminContacts", Property::AdminContacts, 965),
        ("donationLinks", Property::DonationLinks, 966),
        ("downloadLinks", Property::DownloadLinks, 967),
        ("titleFa", Property::TitleFa, 968),
        ("link", Property::Link, 969),
        ("icon", Property::Icon, 970),
        ("imageUrl", Property::ImageUrl, 971),
        ("isDirect", Property::IsDirect, 972),
    ];

    for (name, prop, id) in cases {
        assert_eq!(Property::parse(name), Some(prop));
        assert_eq!(prop.as_str(), name);
        assert_eq!(Property::from_id(id), Some(prop));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p registry@0.16.25 --lib test_deltachat_relay_properties_mapping -- --nocapture`
Expected: FAIL (compilation error, variants not defined).

- [ ] **Step 3: Add `Property` variants to `crates/registry/src/schema/properties.rs`**

Append before closing brace of `pub enum Property`:
```rust
    PlatformNameEn = 961,
    PlatformNameFa = 962,
    PlatformIcon = 963,
    PlatformImageUrl = 964,
    AdminContacts = 965,
    DonationLinks = 966,
    DownloadLinks = 967,
    TitleFa = 968,
    Link = 969,
    Icon = 970,
    ImageUrl = 971,
    IsDirect = 972,
```

- [ ] **Step 4: Update `properties_impl.rs` with parser, `as_str`, `from_id` mappings, and bump `COUNT`**

1. In `Property::parse` inside `tiny_map!`:
```rust
            b"platformNameEn" => Property::PlatformNameEn,
            b"platformNameFa" => Property::PlatformNameFa,
            b"platformIcon" => Property::PlatformIcon,
            b"platformImageUrl" => Property::PlatformImageUrl,
            b"adminContacts" => Property::AdminContacts,
            b"donationLinks" => Property::DonationLinks,
            b"downloadLinks" => Property::DownloadLinks,
            b"titleFa" => Property::TitleFa,
            b"link" => Property::Link,
            b"icon" => Property::Icon,
            b"imageUrl" => Property::ImageUrl,
            b"isDirect" => Property::IsDirect,
```
2. In `Property::as_str`:
```rust
            Property::PlatformNameEn => "platformNameEn",
            Property::PlatformNameFa => "platformNameFa",
            Property::PlatformIcon => "platformIcon",
            Property::PlatformImageUrl => "platformImageUrl",
            Property::AdminContacts => "adminContacts",
            Property::DonationLinks => "donationLinks",
            Property::DownloadLinks => "downloadLinks",
            Property::TitleFa => "titleFa",
            Property::Link => "link",
            Property::Icon => "icon",
            Property::ImageUrl => "imageUrl",
            Property::IsDirect => "isDirect",
```
3. In `Property::from_id`:
```rust
            961 => Some(Property::PlatformNameEn),
            962 => Some(Property::PlatformNameFa),
            963 => Some(Property::PlatformIcon),
            964 => Some(Property::PlatformImageUrl),
            965 => Some(Property::AdminContacts),
            966 => Some(Property::DonationLinks),
            967 => Some(Property::DownloadLinks),
            968 => Some(Property::TitleFa),
            969 => Some(Property::Link),
            970 => Some(Property::Icon),
            971 => Some(Property::ImageUrl),
            972 => Some(Property::IsDirect),
```
4. Bump `Property::COUNT`:
Change `const COUNT: usize = 961;` to `const COUNT: usize = 973;`.

- [ ] **Step 5: Run test to verify it passes**

Run: `cargo test -p registry@0.16.25 --lib test_deltachat_relay_properties_mapping -- --nocapture`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add crates/registry/src/schema/properties.rs crates/registry/src/schema/properties_impl.rs
git commit -m "feat(registry): add property variants for deltachat relay page configuration"
```

---

### Task 2: Implement Registry Structs, Pickle v5, and JMAP Patch

**Files:**
- Modify: `crates/registry/src/schema/structs.rs:6320-6380`
- Modify: `crates/registry/src/schema/structs_impl.rs:47760-48280`

**Interfaces:**
- Consumes: `Property` enum from Task 1, `List<T>`, `Pickle`, `IntoValue`, `RegistryJsonPropertyPatch`.
- Produces: `DeltaChatLink`, `DeltaChatDownloadLink`, extended `DeltaChat` struct with version 5 pickle serialization, sanitized validation, and `patch_empty_ok` JMAP property patching.

- [ ] **Step 1: Write failing tests for DeltaChat Pickle v4 -> v5 migration and roundtrip**

In `crates/registry/src/schema/structs_impl.rs`:
```rust
#[test]
fn test_deltachat_pickle_v4_to_v5_defaults() {
    let dc_v5 = DeltaChat::default();
    assert_eq!(dc_v5.platform_name_en, "MailiaM");
    assert_eq!(dc_v5.platform_name_fa, "میلیم");
    assert_eq!(dc_v5.platform_icon, "");
    assert_eq!(dc_v5.platform_image_url, "");
    assert!(dc_v5.admin_contacts.is_empty());
    assert!(dc_v5.donation_links.is_empty());
    assert_eq!(dc_v5.download_links.len(), 6);
    assert_eq!(dc_v5.download_links[0].id, "google_play");
    assert_eq!(dc_v5.download_links[5].id, "direct_server");
    assert!(dc_v5.download_links[5].is_direct);

    // Roundtrip test via to_pickled_vec
    let pickled = dc_v5.to_pickled_vec();
    let mut stream = crate::pickle::PickledStream::new(&pickled).expect("valid stream");
    let unpickled = DeltaChat::unpickle(&mut stream).expect("unpickle v5");
    assert_eq!(unpickled, dc_v5);
}

#[test]
fn test_deltachat_relay_link_security_validation() {
    let mut dc = DeltaChat::default();
    let mut errors = Vec::new();
    assert!(dc.validate(&mut errors));

    // Test XSS rejection
    dc.admin_contacts.push(DeltaChatLink {
        id: "xss".into(),
        title: "Bad".into(),
        title_fa: "".into(),
        link: "javascript:alert(1)".into(),
        icon: "".into(),
        image_url: "".into(),
    });
    assert!(!dc.validate(&mut errors));
    errors.clear();

    // Test protocol-relative rejection (//)
    dc.admin_contacts[0].link = "//attacker.com/evil.apk".into();
    assert!(!dc.validate(&mut errors));
    errors.clear();

    // Test backslash relative rejection (/\\)
    dc.admin_contacts[0].link = "/\\\\attacker.com/evil.apk".into();
    assert!(!dc.validate(&mut errors));
    errors.clear();

    // Test rejection of ASCII control characters
    dc.admin_contacts[0].link = "/downloads/good.apk\r\n".into();
    assert!(!dc.validate(&mut errors));
    errors.clear();

    // Test rejection of Unicode Bidi overrides
    dc.admin_contacts[0].title = "good\u{202E}txt.apk".into();
    assert!(!dc.validate(&mut errors));
    errors.clear();

    // Test valid relative URL acceptance
    dc.admin_contacts[0].title = "Support".into();
    dc.admin_contacts[0].link = "/downloads/good.apk".into();
    assert!(dc.validate(&mut errors));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p registry@0.16.25 --lib test_deltachat_pickle_v4_to_v5_defaults -- --nocapture`
Expected: FAIL (compilation error, struct fields not defined).

- [ ] **Step 3: Define `DeltaChatLink` and `DeltaChatDownloadLink` in `structs.rs`**

In `crates/registry/src/schema/structs.rs`:
```rust
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct DeltaChatLink {
    #[serde(rename = "id", deserialize_with = "deserialize_null_default")]
    pub id: String,
    #[serde(rename = "title", deserialize_with = "deserialize_null_default")]
    pub title: String,
    #[serde(rename = "titleFa", deserialize_with = "deserialize_null_default")]
    pub title_fa: String,
    #[serde(rename = "link", deserialize_with = "deserialize_null_default")]
    pub link: String,
    #[serde(rename = "icon", deserialize_with = "deserialize_null_default")]
    pub icon: String,
    #[serde(rename = "imageUrl", deserialize_with = "deserialize_null_default")]
    pub image_url: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct DeltaChatDownloadLink {
    #[serde(rename = "id", deserialize_with = "deserialize_null_default")]
    pub id: String,
    #[serde(rename = "title", deserialize_with = "deserialize_null_default")]
    pub title: String,
    #[serde(rename = "titleFa", deserialize_with = "deserialize_null_default")]
    pub title_fa: String,
    #[serde(rename = "link", deserialize_with = "deserialize_null_default")]
    pub link: String,
    #[serde(rename = "isDirect")]
    pub is_direct: bool,
    #[serde(rename = "icon", deserialize_with = "deserialize_null_default")]
    pub icon: String,
    #[serde(rename = "imageUrl", deserialize_with = "deserialize_null_default")]
    pub image_url: String,
}
```

- [ ] **Step 4: Extend `DeltaChat` struct in `structs.rs`**

Add fields to `pub struct DeltaChat`:
```rust
    #[serde(rename = "platformNameEn", deserialize_with = "deserialize_null_default")]
    pub platform_name_en: String,
    #[serde(rename = "platformNameFa", deserialize_with = "deserialize_null_default")]
    pub platform_name_fa: String,
    #[serde(rename = "platformIcon", deserialize_with = "deserialize_null_default")]
    pub platform_icon: String,
    #[serde(rename = "platformImageUrl", deserialize_with = "deserialize_null_default")]
    pub platform_image_url: String,
    #[serde(rename = "adminContacts")]
    pub admin_contacts: List<DeltaChatLink>,
    #[serde(rename = "donationLinks")]
    pub donation_links: List<DeltaChatLink>,
    #[serde(rename = "downloadLinks")]
    pub download_links: List<DeltaChatDownloadLink>,
```

- [ ] **Step 5: Implement `Pickle`, `Default`, `IntoValue`, `RegistryJsonPropertyPatch`, and validation in `structs_impl.rs`**

1. Implement `Default`, `Pickle`, `IntoValue`, and `RegistryJsonPropertyPatch` for `DeltaChatLink`:
   - Use `patch_empty_ok` for `title_fa`, `icon`, `image_url`, `link`.
2. Implement `Default`, `Pickle`, `IntoValue`, and `RegistryJsonPropertyPatch` for `DeltaChatDownloadLink`:
   - Handle `Property::IsDirect => self.is_direct.patch(pointer, value)`.
   - Use `patch_empty_ok` for `title_fa`, `icon`, `image_url`, `link`.
3. Bump `const VERSION: u8 = 5;` in `impl ObjectImpl for DeltaChat`.
4. In `DeltaChat::validate`:
   - Enforce clean text (no ASCII control characters and no Unicode Bidi overrides `\u{202A}..=\u{202E}`, `\u{2066}..=\u{2069}`).
   - Validate length caps: `platform_name_en` / `platform_name_fa` <= 64, `platform_icon` / `platform_image_url` <= 512.
   - Validate list lengths <= 20 items each.
   - Validate item lengths: `id` <= 64, `title` / `title_fa` <= 128, `icon` <= 128, `image_url` <= 1024, `link` <= 1024.
   - Validate link URLs with lowercase scheme allowlist, rejecting control characters, `//`, and `/\\`:
     ```rust
     fn is_safe_link(s: &str) -> bool {
         if s.chars().any(|c| c.is_ascii_control() || ('\u{202A}'..='\u{202E}').contains(&c) || ('\u{2066}'..='\u{2069}').contains(&c)) || s.len() > 1024 {
             return false;
         }
         let lower = s.trim().to_ascii_lowercase();
         lower.is_empty()
             || lower.starts_with("https://")
             || lower.starts_with("http://")
             || lower.starts_with("mailto:")
             || lower.starts_with("tg:")
             || lower.starts_with("matrix:")
             || lower.starts_with("bitcoin:")
             || lower.starts_with("monero:")
             || (lower.starts_with('/') && !lower.starts_with("//") && !lower.starts_with("/\\"))
     }
     ```
5. In `DeltaChat::pickle`: Append pickling of the 7 new fields.
6. In `DeltaChat::unpickle`: When `stream.version() >= 5`, unpickle the 7 new fields.
7. In `DeltaChat::default()`: Set `"MailiaM"`, `"میلیم"`, and pre-populate the 6 default download links.
8. In `IntoValue for DeltaChat`: Bump capacity from 22 to 29, insert all 7 properties.
9. In `RegistryJsonPropertyPatch for DeltaChat`: Add patch arms for the new fields using `patch_empty_ok` for `platform_icon` and `platform_image_url`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `cargo test -p registry@0.16.25 --lib test_deltachat_pickle_v4_to_v5_defaults test_deltachat_relay_link_security_validation -- --nocapture`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add crates/registry/src/schema/structs.rs crates/registry/src/schema/structs_impl.rs
git commit -m "feat(registry): implement deltachat relay page fields, pickle v5, and security validation"
```

---

### Task 3: DeltaChat Settings, Endpoint Handler, and Empty-Link Filter

**Files:**
- Modify: `crates/deltachat/src/config.rs:60-140`
- Modify: `crates/deltachat/src/models.rs:90-130`
- Modify: `crates/deltachat/src/handlers/system.rs:30-80`

**Interfaces:**
- Consumes: `DeltaChat` from `crates/registry`, `DeltaChatSettings`, `ConfigDiscoveryResponse`.
- Produces: Enhanced `ConfigDiscoveryResponse` returned by `GET /api/v1/config` containing `platform_name`, `platform_icon`, `platform_image_url`, `admin_contacts`, `donation_links`, and pre-allocated filtered `download_links`.

- [ ] **Step 1: Write unit tests in `crates/deltachat/src/handlers/system.rs`**

```rust
#[test]
fn test_config_handler_relay_page_data() {
    let mut settings = DeltaChatSettings::default();
    settings.platform_name_en = "MailiaM".into();
    settings.platform_name_fa = "میلیم".into();
    settings.admin_contacts = vec![
        crate::config::LinkItem {
            id: "tg".into(),
            title: "Telegram".into(),
            title_fa: "تلگرام".into(),
            link: "https://t.me/example".into(),
            icon: "telegram".into(),
            image_url: "".into(),
        },
        crate::config::LinkItem {
            id: "empty_contact".into(),
            title: "Empty".into(),
            title_fa: "".into(),
            link: "   ".into(), // Empty link must be filtered out!
            icon: "".into(),
            image_url: "".into(),
        },
    ];
    settings.download_links = vec![
        crate::config::DownloadLinkItem {
            id: "gp".into(),
            title: "Google Play".into(),
            title_fa: "گوگل پلی".into(),
            link: "https://play.google.com".into(),
            is_direct: false,
            icon: "google-play".into(),
            image_url: "".into(),
        },
        crate::config::DownloadLinkItem {
            id: "direct_empty".into(),
            title: "Direct APK".into(),
            title_fa: "".into(),
            link: "   ".into(), // Empty link must be filtered out!
            is_direct: true,
            icon: "download".into(),
            image_url: "".into(),
        },
    ];

    let altcha = AltchaEngine::new(b"secret".to_vec(), 100_000);
    let endpoints = test_endpoints();
    let resp = handle_config(&settings, &altcha, "localhost".into(), endpoints, "argon2id").unwrap();

    assert_eq!(resp.platform_name.en, "MailiaM");
    assert_eq!(resp.platform_name.fa, "میلیم");
    assert_eq!(resp.admin_contacts.len(), 1);
    assert_eq!(resp.admin_contacts[0].id, "tg");
    // Empty link filtered:
    assert_eq!(resp.download_links.len(), 1);
    assert_eq!(resp.download_links[0].id, "gp");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p deltachat@0.16.25 --lib test_config_handler_relay_page_data -- --nocapture`
Expected: FAIL (compilation error, fields not defined).

- [ ] **Step 3: Update `crates/deltachat/src/config.rs`**

1. Define `LinkItem` and `DownloadLinkItem`:
```rust
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct LinkItem {
    #[serde(default)]
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub title_fa: String,
    pub link: String,
    #[serde(default)]
    pub icon: String,
    #[serde(default)]
    pub image_url: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct DownloadLinkItem {
    #[serde(default)]
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub title_fa: String,
    pub link: String,
    #[serde(default)]
    pub is_direct: bool,
    #[serde(default)]
    pub icon: String,
    #[serde(default)]
    pub image_url: String,
}
```
2. Add fields to `DeltaChatSettings`:
```rust
    pub platform_name_en: String,
    pub platform_name_fa: String,
    pub platform_icon: String,
    pub platform_image_url: String,
    pub admin_contacts: Vec<LinkItem>,
    pub donation_links: Vec<LinkItem>,
    pub download_links: Vec<DownloadLinkItem>,
```
3. Update `From<registry::DeltaChat> for DeltaChatSettings` using `c.admin_contacts.0.into_values()`.

- [ ] **Step 4: Update `crates/deltachat/src/models.rs`**

1. Define `PlatformNameConfig`:
```rust
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlatformNameConfig {
    pub en: String,
    pub fa: String,
}
```
2. Add new fields to `ConfigDiscoveryResponse`:
```rust
    pub platform_name: PlatformNameConfig,
    pub platform_icon: String,
    pub platform_image_url: String,
    pub admin_contacts: Vec<LinkItem>,
    pub donation_links: Vec<LinkItem>,
    pub download_links: Vec<DownloadLinkItem>,
```

- [ ] **Step 5: Update `handle_config` in `crates/deltachat/src/handlers/system.rs`**

Pre-allocate and filter download links, contacts, and donation links against empty strings:
```rust
    let platform_name = PlatformNameConfig {
        en: if settings.platform_name_en.trim().is_empty() {
            "MailiaM".into()
        } else {
            settings.platform_name_en.clone()
        },
        fa: if settings.platform_name_fa.trim().is_empty() {
            "میلیم".into()
        } else {
            settings.platform_name_fa.clone()
        },
    };

    let mut download_links = Vec::with_capacity(settings.download_links.len());
    download_links.extend(
        settings
            .download_links
            .iter()
            .filter(|d| !d.link.trim().is_empty())
            .cloned(),
    );

    let mut admin_contacts = Vec::with_capacity(settings.admin_contacts.len());
    admin_contacts.extend(
        settings
            .admin_contacts
            .iter()
            .filter(|c| !c.link.trim().is_empty())
            .cloned(),
    );

    let mut donation_links = Vec::with_capacity(settings.donation_links.len());
    donation_links.extend(
        settings
            .donation_links
            .iter()
            .filter(|d| !d.link.trim().is_empty())
            .cloned(),
    );
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cargo test -p deltachat@0.16.25 --lib test_config_handler_relay_page_data -- --nocapture`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add crates/deltachat/src/config.rs crates/deltachat/src/models.rs crates/deltachat/src/handlers/system.rs
git commit -m "feat(deltachat): expose relay page branding, contacts, and download links in config api"
```

---

### Task 4: WebUI Schema, Menu Layouts, and Socket Security Inline Guidance

**Files:**
- Modify: `resources/schema/schema.json.gz`
- Modify: `resources/schema/schema.json.sha256`

**Interfaces:**
- Consumes: Python 3 script to unpack, patch JSON, format with `indent=2`, and recompress `resources/schema/schema.json.gz` using `gzip -n -9`.
- Produces: Updated WebUI schema with:
  - `Relay Page` sub-item under `DeltaChat` menu in `layouts`
  - `x:DeltaChat/DeltaChatRelayPage` in `forms`
  - `x:DeltaChatLink` and `x:DeltaChatDownloadLink` in `schemas`, `fields`, `forms`
  - Properties in `x:DeltaChat` (`platformNameEn`, `platformNameFa`, `platformIcon`, `platformImageUrl`, `adminContacts`, `donationLinks`, `downloadLinks`)
  - Populated default download links map in `defaults`
  - Clear explanations of valid options (`ssl`, `starttls`, `plain`, `default`) for `imapSecurity` and `smtpSecurity`.

- [ ] **Step 1: Write Python script to apply schema changes and verify integrity**

Create `/tmp/update_schema.py`:
- Read `resources/schema/schema.json.gz`.
- Add `x:DeltaChatLink` and `x:DeltaChatDownloadLink` schemas, fields, and modal forms.
- Add properties to `fields["x:DeltaChat"]["properties"]`.
- Update `imapSecurity` and `smtpSecurity` descriptions:
  - `imapSecurity`: `"IMAP socket security. Options: ssl (implicit TLS, typically port 993), starttls (explicit STARTTLS), plain (cleartext), default"`
  - `smtpSecurity`: `"SMTP socket security. Options: ssl (implicit TLS, typically port 465), starttls (explicit STARTTLS, typically port 587/25), plain (cleartext), default"`
- Add `x:DeltaChat/DeltaChatRelayPage` to `forms`.
- Add `Relay Page` link item to `layouts` under DeltaChat container.
- Write formatted JSON (`indent=2`) to `/tmp/schema.json`.

- [ ] **Step 2: Run Python update script and compress with `gzip -n -9`**

```bash
python3 /tmp/update_schema.py
gzip -n -9 -c /tmp/schema.json > resources/schema/schema.json.gz
sha256sum resources/schema/schema.json.gz | awk '{print $1}' > resources/schema/schema.json.sha256
```

- [ ] **Step 3: Verify schema integrity with test script**

```bash
python3 -c "import gzip, json; d=json.load(gzip.open('resources/schema/schema.json.gz')); \
assert 'x:DeltaChat/DeltaChatRelayPage' in d['forms']; \
assert 'x:DeltaChatLink' in d['schemas']; \
assert 'x:DeltaChatDownloadLink' in d['schemas']; \
assert 'starttls' in d['fields']['x:DeltaChat']['properties']['imapSecurity']['description']; \
assert 'starttls' in d['fields']['x:DeltaChat']['properties']['smtpSecurity']['description']; \
assert any(i.get('name') == 'Relay Page' for x in d['layouts'] for i in x.get('items', []) if isinstance(i, dict) and 'Relay Page' in str(i)); \
print('SCHEMA OK')"
```
Expected output: `SCHEMA OK`.

- [ ] **Step 4: Verify checksum matches**

```bash
actual=$(sha256sum resources/schema/schema.json.gz | awk '{print $1}')
expected=$(cat resources/schema/schema.json.sha256)
test "$actual" = "$expected" && echo "CHECKSUM OK"
```
Expected output: `CHECKSUM OK`.

- [ ] **Step 5: Verify workspace build and tests**

```bash
cargo check -p registry@0.16.25
cargo check -p deltachat@0.16.25
cargo test -p registry@0.16.25 --lib
cargo test -p deltachat@0.16.25 --lib
```
Expected: All tests PASS.

- [ ] **Step 6: Commit**

```bash
git add resources/schema/schema.json.gz resources/schema/schema.json.sha256
git commit -m "feat(webui): add relay page settings form and enhance socket security guidance"
```

---

## Plan Self-Review Checklist

1. **Spec Coverage:**
   - WebUI sub-menu "Relay Page" under DeltaChat -> Covered in Task 4.
   - Bilingual platform name (en/fa, default MailiaM/میلیم) -> Covered in Tasks 1, 2, 3, 4.
   - Admin contacts (`[{ id, title, title_fa, link, icon, image_url }]`) -> Covered in Tasks 1, 2, 3, 4.
   - Donation links (`[{ id, title, title_fa, link, icon, image_url }]`) -> Covered in Tasks 1, 2, 3, 4.
   - Download links (`[{ id, title, title_fa, link, is_direct, icon, image_url }]` with 6 defaults) -> Covered in Tasks 1, 2, 3, 4.
   - Empty link filter on direct download, contacts, and donations -> Covered in Task 3.
   - Socket security guidance (`plain`, `ssl`, `starttls`, `default`) -> Covered in Task 4.
2. **Security Audit Fixes Incorporated:**
   - Lowercase scheme allowlist.
   - Protocol-relative (`//`) and backslash (`/\\`) bypass prevention.
   - Control character and Unicode Bidi override character rejection.
   - Optional string clearing bug fixed with `patch_empty_ok`.
   - Empty link filtering extended to contacts and donations.
3. **Rust Audit Fixes Incorporated:**
   - `Property::parse(&str)` and `Property::from_id(u16)`.
   - Bumped `Property::COUNT = 973`.
   - Pre-allocated filtered vectors for download links, contacts, and donations.
   - Fixed `PickledStream` signature usage.
