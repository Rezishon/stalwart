# DeltaChat Relay Page Admin Submenu & /api/v1/config Specification

- **Date:** 2026-10-23
- **Status:** Approved (Incorporating UX/Product & Stalwart-Rust Expert Findings)
- **Authors:** RiseLabs / MailiaM Team
- **Target Components:** `crates/registry`, `crates/deltachat`, `resources/schema/schema.json.gz`, `signup-relay/frontend`

---

## 1. Context & Problem Statement

MailiaM integrates an embedded DeltaChat onboarding & relay single-page application (`signup-relay`). The relay page supports English and Persian (`en`/`fa`) localization, instant 1-click accounts, custom usernames, and client-side password hashing.

Currently:
1. Platform branding (names, icons, badges) is hardcoded or relies purely on static frontend strings.
2. The relay page has no server-driven way to display admin contact channels (e.g. email, Telegram, Matrix).
3. The relay page has no server-driven way to display donation links (e.g. crypto addresses, fiat donation platforms).
4. DeltaChat download links are static or hardcoded, with no direct server-hosted download fallback if external app stores or download mirrors are blocked or inaccessible.
5. In the Stalwart WebUI under `Settings -> DeltaChat -> Endpoints`, the socket security fields for IMAP and SMTP lack clear inline guidance explaining valid options (`plain`, `ssl`, `starttls`, `default`).

---

## 2. Requirements

1. **WebUI Relay Page Sub-menu:**
   - Add a new `Relay Page` sub-item under `Settings -> DeltaChat` container in the Stalwart WebUI.
   - Form view: `x:DeltaChat/DeltaChatRelayPage`.
   - RBAC permission: `sysSystemSettings` (`Permission::SysSystemSettingsUpdate` / `Get`).

2. **Platform Branding (Bilingual):**
   - Editable English name (`platform_name_en`), default `"MailiaM"`.
   - Editable Persian name (`platform_name_fa`), default `"میلیم"`.
   - Optional platform icon (`platform_icon`), default `""` or `"/logo.svg"`.
   - Optional platform banner/logo image (`platform_image_url`), default `""`.
   - Server-side fallback: If stored string is empty, fallback to `"MailiaM"` (en) and `"میلیم"` (fa).

3. **Admin Contact Channels:**
   - Dynamic list of contact channels: `[{ id, title, title_fa, link, icon, image_url }]`.
   - Supports multiple channels (e.g., Support Email, Telegram Group, Matrix Room).
   - `id`: Unique slug (`"support_email"`, `"telegram"`) for React keys and client-side localization lookup.
   - `title`: English title (required).
   - `title_fa`: Persian title (optional; falls back to `title` if empty).
   - `icon`: Lucide icon slug, brand slug (`"telegram"`, `"matrix"`), or SVG/image URL.
   - `image_url`: Badge/logo URL (optional).

4. **Donation Channels:**
   - Dynamic list of donation options: `[{ id, title, title_fa, link, icon, image_url }]`.
   - Supports multiple channels (e.g., Bitcoin, Monero, OpenCollective, ZarinPal).
   - Same bilingual title and icon/image fallback support as contact channels.

5. **Download Links:**
   - Dynamic list of app download channels: `[{ id, title, title_fa, link, is_direct, icon, image_url }]`.
   - Pre-populated default list of official DeltaChat links:
     1. `id: "google_play"`, `title: "Google Play"`, `title_fa: "گوگل پلی"`, `link: "https://play.google.com/store/apps/details?id=chat.delta"`, `is_direct: false`, `icon: "google-play"`
     2. `id: "f_droid"`, `title: "F-Droid"`, `title_fa: "اف‌دروید"`, `link: "https://f-droid.org/packages/chat.delta/"`, `is_direct: false`, `icon: "f-droid"`
     3. `id: "android_apk"`, `title: "Android APK"`, `title_fa: "دانلود فایل APK (رسمی)"`, `link: "https://download.delta.chat/android/"`, `is_direct: false`, `icon: "android"`
     4. `id: "apple_store"`, `title: "iOS App Store"`, `title_fa: "اپ استور اپل"`, `link: "https://apps.apple.com/app/delta-chat/id1459523234"`, `is_direct: false`, `icon: "apple"`
     5. `id: "desktop"`, `title: "Desktop"`, `title_fa: "نسخه دسکتاپ (ویندوز / مک / لینوکس)"`, `link: "https://delta.chat/en/download"`, `is_direct: false`, `icon: "desktop"`
     6. `id: "direct_server"`, `title: "Direct Server Download"`, `title_fa: "دانلود مستقیم سرور"`, `link: ""`, `is_direct: true`, `icon: "download"`
   - Server-side empty-link filter: Any download link with an empty `link` (e.g. unconfigured direct server download) is filtered out in `handle_config` so the frontend never renders dead links.

6. **Socket Security Description in WebUI:**
   - Update `imapSecurity` and `smtpSecurity` field descriptions in `schema.json.gz` to clearly state valid options:
     - `imapSecurity`: `"IMAP socket security. Options: ssl (implicit TLS, typically port 993), starttls (explicit STARTTLS), plain (cleartext), default"`
     - `smtpSecurity`: `"SMTP socket security. Options: ssl (implicit TLS, typically port 465), starttls (explicit STARTTLS, typically port 587/25), plain (cleartext), default"`

7. **Zero-Overhead / KISS / DRY:**
   - Extend the existing `DeltaChat` singleton (`ObjectType::DeltaChat = 117`).
   - Bump `Pickle` version from 4 to 5 with seamless backward compatibility for existing deployments.

---

## 3. Architecture & Data Structures

### 3.1. Registry Structs (`crates/registry/src/schema/structs.rs`)

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

Both structs implement:
- `Default`: empty strings, `is_direct: false`.
- `Pickle`: sequential field pickling.
- `IntoValue`: conversion to `JmapValue`.

### 3.2. Extended `DeltaChat` Struct (`crates/registry/src/schema/structs.rs`)

```rust
pub struct DeltaChat {
    // ... existing fields ...
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
}
```

### 3.3. Pickle Versioning & Backward Compatibility (`crates/registry/src/schema/structs_impl.rs`)

- Version bump: `const VERSION: u8 = 5;`
- In `DeltaChat::default()`: populate the 6 official download links with IDs, en/fa titles, and icons.
- Deserialization in `DeltaChat::unpickle`:
  ```rust
  if stream.version() >= 5 {
      this.platform_name_en = Pickle::unpickle(stream)?;
      this.platform_name_fa = Pickle::unpickle(stream)?;
      this.platform_icon = Pickle::unpickle(stream)?;
      this.platform_image_url = Pickle::unpickle(stream)?;
      this.admin_contacts = Pickle::unpickle(stream)?;
      this.donation_links = Pickle::unpickle(stream)?;
      this.download_links = Pickle::unpickle(stream)?;
  }
  ```
- Update `IntoValue for DeltaChat` and `RegistryJsonPropertyPatch for DeltaChat` to include all 7 new properties for JMAP get/set and WebUI forms.

### 3.4. Validation Rules (`DeltaChat::validate`)

- `platform_name_en`, `platform_name_fa`: max length 64 characters.
- `platform_icon`, `platform_image_url`: max length 512 characters.
- `admin_contacts`, `donation_links`, `download_links`: max 20 entries each; each item `id` max 64 characters, `title`/`title_fa` max 128 characters, `link` max 1024 characters.

---

## 4. Runtime Configuration & Public API

### 4.1. `DeltaChatSettings` in `crates/deltachat/src/config.rs`

```rust
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

Included in `DeltaChatSettings`:
```rust
pub platform_name_en: String,
pub platform_name_fa: String,
pub platform_icon: String,
pub platform_image_url: String,
pub admin_contacts: Vec<LinkItem>,
pub donation_links: Vec<LinkItem>,
pub download_links: Vec<DownloadLinkItem>,
```

### 4.2. `GET /api/v1/config` JSON Output Contract (`crates/deltachat/src/models.rs`)

```json
{
  "domain": "example.org",
  "registration_open": true,
  "instant_accounts_enabled": true,
  "custom_accounts_enabled": true,
  "endpoints": {
    "imap": { "host": "mail.example.org", "port": 993, "security": "ssl" },
    "smtp": { "host": "mail.example.org", "port": 465, "security": "ssl" }
  },
  "altcha": {
    "required": false,
    "max_number": 100000
  },
  "password_hash_algorithm": "argon2id",
  "certificate_checks": "3",
  "instant_prefix_enabled": true,
  "instant_prefix": "dc_",
  "custom_prefix_enabled": false,
  "custom_prefix": "",
  "platform_name": {
    "en": "MailiaM",
    "fa": "میلیم"
  },
  "platform_icon": "/logo.svg",
  "platform_image_url": "",
  "admin_contacts": [
    {
      "id": "telegram",
      "title": "Telegram Support",
      "title_fa": "پشتیبانی تلگرام",
      "link": "https://t.me/example_support",
      "icon": "telegram",
      "image_url": ""
    }
  ],
  "donation_links": [
    {
      "id": "bitcoin",
      "title": "Bitcoin",
      "title_fa": "بیت‌کوین",
      "link": "bitcoin:1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
      "icon": "bitcoin",
      "image_url": "https://example.org/btc.png"
    }
  ],
  "download_links": [
    {
      "id": "google_play",
      "title": "Google Play",
      "title_fa": "گوگل پلی",
      "link": "https://play.google.com/store/apps/details?id=chat.delta",
      "is_direct": false,
      "icon": "google-play",
      "image_url": ""
    },
    {
      "id": "direct_server",
      "title": "Direct Server Download",
      "title_fa": "دانلود مستقیم سرور",
      "link": "https://example.org/download/deltachat.apk",
      "is_direct": true,
      "icon": "download",
      "image_url": ""
    }
  ]
}
```

In `handle_config`:
- `platform_name.en`: if settings value is empty, fallback to `"MailiaM"`.
- `platform_name.fa`: if settings value is empty, fallback to `"میلیم"`.
- `download_links`: filter out items with empty `link` (`!d.link.trim().is_empty()`).

---

## 5. WebUI Schema Specification (`resources/schema/schema.json.gz`)

### 5.1. Layout Update
Add `Relay Page` under `Settings -> DeltaChat`:
```json
{
  "container": {
    "name": "DeltaChat",
    "icon": "message-square",
    "items": [
      { "name": "General", "type": "link", "viewName": "x:DeltaChat/DeltaChatGeneral" },
      { "name": "Domains", "type": "link", "viewName": "x:DeltaChat/DeltaChatDomains" },
      { "name": "Endpoints", "type": "link", "viewName": "x:DeltaChat/DeltaChatEndpoints" },
      { "name": "Bot Protection", "type": "link", "viewName": "x:DeltaChat/DeltaChatAltcha" },
      { "name": "Relay Page", "type": "link", "viewName": "x:DeltaChat/DeltaChatRelayPage" }
    ]
  }
}
```

### 5.2. Form Definition `x:DeltaChat/DeltaChatRelayPage`
```json
{
  "title": "DeltaChat Relay Page Settings",
  "subtitle": "Customize branding, admin contacts, donation options, and download links for the onboarding relay page",
  "sections": [
    {
      "title": "Platform Branding",
      "fields": [
        { "name": "platformNameEn", "label": "Platform Name (English)", "placeholder": "MailiaM" },
        { "name": "platformNameFa", "label": "Platform Name (Persian)", "placeholder": "میلیم" },
        { "name": "platformIcon", "label": "Platform Icon (URL or icon identifier)", "placeholder": "/logo.svg" },
        { "name": "platformImageUrl", "label": "Platform Banner/Logo Image (URL)", "placeholder": "https://example.org/banner.png" }
      ]
    },
    {
      "title": "Admin Contacts",
      "fields": [
        { "name": "adminContacts", "label": "Contact Channels" }
      ]
    },
    {
      "title": "Donations",
      "fields": [
        { "name": "donationLinks", "label": "Donation Links" }
      ]
    },
    {
      "title": "Download Links",
      "fields": [
        { "name": "downloadLinks", "label": "Client Download Links" }
      ]
    }
  ]
}
```

### 5.3. Sub-Object Schemas & Forms
- `x:DeltaChatLink`:
  - `fields`: `id` (string), `title` (string), `titleFa` (string), `link` (string), `icon` (string), `imageUrl` (string).
  - `forms`: Section "Link Item" with ID, English Title, Persian Title, URL, Icon, Image URL inputs.
- `x:DeltaChatDownloadLink`:
  - `fields`: `id` (string), `title` (string), `titleFa` (string), `link` (string), `isDirect` (boolean), `icon` (string), `imageUrl` (string).
  - `forms`: Section "Download Item" with ID, English Title, Persian Title, URL, Direct Download toggle, Icon, Image URL inputs.

### 5.4. Field Guidance Updates for `x:DeltaChat/DeltaChatEndpoints`
- Update `imapSecurity`:
  - Description: `"IMAP socket security. Options: ssl (implicit TLS, typically port 993), starttls (explicit STARTTLS), plain (cleartext), default"`
- Update `smtpSecurity`:
  - Description: `"SMTP socket security. Options: ssl (implicit TLS, typically port 465), starttls (explicit STARTTLS, typically port 587/25), plain (cleartext), default"`

### 5.5. Re-compression & Checksum
- `gzip -n -9 -c /tmp/schema.json > resources/schema/schema.json.gz` (using `-n` to prevent gzip timestamp drift).
- `sha256sum resources/schema/schema.json.gz | awk '{print $1}' > resources/schema/schema.json.sha256`.

---

## 6. Frontend Compatibility Specification (`signup-relay`)

In `signup-relay/frontend/src/services/types.ts`:
```typescript
export interface LinkItem {
  id?: string;
  title: string;
  title_fa?: string;
  link: string;
  icon?: string;
  image_url?: string;
}

export interface DownloadLinkItem {
  id?: string;
  title: string;
  title_fa?: string;
  link: string;
  is_direct?: boolean;
  icon?: string;
  image_url?: string;
}

export interface PlatformNameConfig {
  en: string;
  fa: string;
}

export interface ServerConfig {
  domain: string;
  registration_open: boolean;
  instant_accounts_enabled?: boolean;
  custom_accounts_enabled?: boolean;
  instant_prefix_enabled?: boolean;
  instant_prefix?: string;
  custom_prefix_enabled?: boolean;
  custom_prefix?: string;
  password_hash_algorithm: string;
  certificate_checks: string;
  endpoints: EndpointsConfig;
  altcha?: AltchaConfig;
  platform_name?: PlatformNameConfig;
  platform_icon?: string;
  platform_image_url?: string;
  admin_contacts?: LinkItem[];
  donation_links?: LinkItem[];
  download_links?: DownloadLinkItem[];
}
```

### Rendering & UX Guidelines:
1. **Title Selection:** Use `(lang === 'fa' && item.title_fa) ? item.title_fa : item.title`.
2. **Icon / Image Fallback Hierarchy:**
   - If `image_url` is non-empty -> render `<img src={item.image_url} />`.
   - Else if `icon` starts with `http://`, `https://`, or `/` -> render `<img src={item.icon} />`.
   - Else if `icon` matches a known brand icon (`telegram`, `matrix`, `bitcoin`, `google-play`, `f-droid`, `apple`, `desktop`, `download`) -> render inline SVG.
   - Else fallback to default category Lucide icon + text title.
3. **Censorship / Iran UX:**
   - For `fa` locale, sort items where `is_direct: true` and APK links to the top before Google Play.
   - Display `is_direct` download with prominent "دانلود مستقیم سرور" badge.
   - Wrap crypto addresses and links in `dir="ltr"` to avoid bidi rendering bugs.
4. **Link Sanitization:**
   - Frontend validates link starts with `https://`, `http://`, `mailto:`, `tg:`, `matrix:`, `bitcoin:`, or `monero:` before rendering in `<a>` tags with `rel="noopener noreferrer" target="_blank"`.

---

## 7. Testing & Verification Plan

1. **Pickle Serialization Tests (`crates/registry`):**
   - Test v4 blob unpickling into v5 struct.
   - Test v5 full struct pickling and unpickling roundtrip.
   - Test validation of max length and array bounds.
2. **DeltaChat Handler Tests (`crates/deltachat`):**
   - Unit test `handle_config` ensuring all new fields are populated and serialized to JSON.
   - Assert `platform_name`, `admin_contacts`, `donation_links`, `download_links` serialize with correct keys.
   - Test empty link filtering for download links.
3. **Schema Integrity:**
   - Python assertion script:
     - Assert `x:DeltaChat/DeltaChatRelayPage` in `forms`.
     - Assert `x:DeltaChatLink` and `x:DeltaChatDownloadLink` in `fields`, `forms`, `schemas`.
     - Assert menu item in `layouts`.
     - Check `sha256sum` matches `resources/schema/schema.json.sha256`.
4. **Compilation & Clippy Checks:**
   - `cargo check -p registry@0.16.25`
   - `cargo check -p deltachat@0.16.25`
   - `cargo test -p registry@0.16.25 --lib deltachat`
   - `cargo test -p deltachat@0.16.25 --lib`
