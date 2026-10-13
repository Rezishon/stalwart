/*
 * SPDX-FileCopyrightText: 2026 Stalwart Labs LLC <hello@stalw.art>
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
 */

include!(concat!(env!("OUT_DIR"), "/relay_embed.rs"));

const NO_CACHE: &str = "no-cache";
const LOGO_CACHE_CONTROL: &str = "public, max-age=86400";
const IMMUTABLE_CACHE_CONTROL: &str = "public, max-age=31536000, immutable";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WebAsset {
    pub bytes: &'static [u8],
    pub content_type: &'static str,
    pub cache_control: &'static str,
}

pub fn get_web_asset(path: &str) -> Option<WebAsset> {
    let clean_path = path.split('?').next().unwrap_or(path);
    let trimmed = clean_path.trim_matches('/');

    if trimmed.starts_with("api/")
        || trimmed == "api"
        || trimmed.starts_with("apps/xdcstore/")
        || trimmed == "apps/xdcstore"
    {
        return None;
    }

    if let Some((bytes, content_type)) = lookup(trimmed) {
        return Some(WebAsset {
            bytes,
            content_type,
            cache_control: cache_control(trimmed, content_type),
        });
    }

    if trimmed.is_empty() {
        return lookup("index.html").map(|(bytes, content_type)| WebAsset {
            bytes,
            content_type,
            cache_control: NO_CACHE,
        });
    }

    let last_segment = trimmed.rsplit('/').next().unwrap_or(trimmed);
    if !last_segment.contains('.') {
        lookup("index.html").map(|(bytes, content_type)| WebAsset {
            bytes,
            content_type,
            cache_control: NO_CACHE,
        })
    } else {
        None
    }
}

fn cache_control(path: &str, content_type: &str) -> &'static str {
    if content_type.starts_with("text/html") {
        NO_CACHE
    } else if path == "logo.svg" {
        LOGO_CACHE_CONTROL
    } else if path.starts_with("assets/") {
        IMMUTABLE_CACHE_CONTROL
    } else {
        NO_CACHE
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_root_and_index() {
        for path in ["", "/", "/index.html", "index.html", "/?v=123", "/index.html?token=abc"] {
            let asset = get_web_asset(path).unwrap_or_else(|| panic!("failed for path: {path}"));
            assert!(asset.content_type.starts_with("text/html"), "{path}");
            assert_eq!(asset.cache_control, "no-cache");
            assert!(asset.bytes.starts_with(b"<!"), "{path}");
        }
    }

    #[test]
    fn test_named_html_pages() {
        for path in ["/apps", "apps", "/apps.html", "apps.html"] {
            let asset = get_web_asset(path).unwrap_or_else(|| panic!("failed for path: {path}"));
            assert!(asset.content_type.starts_with("text/html"));
            assert_eq!(asset.cache_control, "no-cache");
        }
        assert!(get_web_asset("/docs").unwrap().content_type.starts_with("text/html"));
        assert!(get_web_asset("/share").unwrap().content_type.starts_with("text/html"));
    }

    #[test]
    fn test_logo_svg() {
        let asset = get_web_asset("/logo.svg").expect("logo");
        assert_eq!(asset.content_type, "image/svg+xml");
        assert_eq!(asset.cache_control, "public, max-age=86400");
    }

    #[test]
    fn test_hashed_js_and_css_bundles() {
        let js = get_web_asset("/assets/main-D6MKEcMq.js").expect("main js");
        assert!(js.content_type.contains("javascript"));
        assert_eq!(js.cache_control, IMMUTABLE_CACHE_CONTROL);

        let css = get_web_asset("/assets/main-DO0WF65x.css").expect("main css");
        assert!(css.content_type.contains("css"));
        assert_eq!(css.cache_control, IMMUTABLE_CACHE_CONTROL);

        assert!(get_web_asset("/assets/missing.png").is_none());
        assert!(get_web_asset("/assets/custom-bundle.js").is_none());
    }

    #[test]
    fn test_spa_routes_fallback() {
        for path in ["/instant", "/custom", "/qr", "instant", "/instant?user=alice"] {
            let asset = get_web_asset(path).unwrap_or_else(|| panic!("failed for path: {path}"));
            assert!(asset.content_type.starts_with("text/html"));
            assert_eq!(asset.cache_control, "no-cache");
        }
    }

    #[test]
    fn test_none_for_api_and_unknown_extensions() {
        for path in [
            "/api",
            "/api/",
            "/api/v1/foo",
            "/apps/xdcstore",
            "/apps/xdcstore/chess.xdc",
            "/missing.png",
            "/favicon.ico",
        ] {
            assert!(
                get_web_asset(path).is_none(),
                "path should return None: {path}"
            );
        }
    }
}
