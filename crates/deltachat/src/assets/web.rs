/*
 * SPDX-FileCopyrightText: 2026 Stalwart Labs LLC <hello@stalw.art>
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
 */

static INDEX_HTML: &[u8] = include_bytes!("../../assets/index.html");
static APPS_HTML: &[u8] = include_bytes!("../../assets/apps.html");
static DOCS_HTML: &[u8] = include_bytes!("../../assets/docs.html");
static SHARE_HTML: &[u8] = include_bytes!("../../assets/share.html");
static LOGO_SVG: &[u8] = include_bytes!("../../assets/logo.svg");
static MAIN_JS: &[u8] = include_bytes!("../../assets/assets/main-D6MKEcMq.js");
static MAIN_CSS: &[u8] = include_bytes!("../../assets/assets/main-DO0WF65x.css");

const HTML_CONTENT_TYPE: &str = "text/html; charset=utf-8";
const SVG_CONTENT_TYPE: &str = "image/svg+xml";
const JS_CONTENT_TYPE: &str = "application/javascript; charset=utf-8";
const CSS_CONTENT_TYPE: &str = "text/css; charset=utf-8";

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

    match trimmed {
        "" | "index.html" => Some(WebAsset {
            bytes: INDEX_HTML,
            content_type: HTML_CONTENT_TYPE,
            cache_control: NO_CACHE,
        }),
        "apps" | "apps.html" => Some(WebAsset {
            bytes: APPS_HTML,
            content_type: HTML_CONTENT_TYPE,
            cache_control: NO_CACHE,
        }),
        "docs" | "docs.html" => Some(WebAsset {
            bytes: DOCS_HTML,
            content_type: HTML_CONTENT_TYPE,
            cache_control: NO_CACHE,
        }),
        "share" | "share.html" => Some(WebAsset {
            bytes: SHARE_HTML,
            content_type: HTML_CONTENT_TYPE,
            cache_control: NO_CACHE,
        }),
        "logo.svg" => Some(WebAsset {
            bytes: LOGO_SVG,
            content_type: SVG_CONTENT_TYPE,
            cache_control: LOGO_CACHE_CONTROL,
        }),
        s if s.starts_with("assets/") && s.ends_with(".js") => Some(WebAsset {
            bytes: MAIN_JS,
            content_type: JS_CONTENT_TYPE,
            cache_control: IMMUTABLE_CACHE_CONTROL,
        }),
        s if s.starts_with("assets/") && s.ends_with(".css") => Some(WebAsset {
            bytes: MAIN_CSS,
            content_type: CSS_CONTENT_TYPE,
            cache_control: IMMUTABLE_CACHE_CONTROL,
        }),
        s if s.starts_with("api/")
            || s == "api"
            || s.starts_with("apps/xdcstore/")
            || s == "apps/xdcstore" =>
        {
            None
        }
        s => {
            let last_segment = s.rsplit('/').next().unwrap_or(s);
            if !last_segment.contains('.') {
                Some(WebAsset {
                    bytes: INDEX_HTML,
                    content_type: HTML_CONTENT_TYPE,
                    cache_control: NO_CACHE,
                })
            } else {
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_root_and_index() {
        for path in ["", "/", "/index.html", "index.html", "/?v=123", "/index.html?token=abc"] {
            let asset = get_web_asset(path).unwrap_or_else(|| panic!("failed for path: {path}"));
            assert_eq!(asset.bytes, INDEX_HTML);
            assert_eq!(asset.content_type, "text/html; charset=utf-8");
            assert_eq!(asset.cache_control, "no-cache");
        }
    }

    #[test]
    fn test_named_html_pages() {
        for path in ["/apps", "apps", "/apps.html", "apps.html", "/apps?sort=name"] {
            let asset = get_web_asset(path).unwrap_or_else(|| panic!("failed for path: {path}"));
            assert_eq!(asset.bytes, APPS_HTML);
            assert_eq!(asset.content_type, "text/html; charset=utf-8");
            assert_eq!(asset.cache_control, "no-cache");
        }

        for path in ["/docs", "docs", "/docs.html", "docs.html"] {
            let asset = get_web_asset(path).unwrap_or_else(|| panic!("failed for path: {path}"));
            assert_eq!(asset.bytes, DOCS_HTML);
            assert_eq!(asset.content_type, "text/html; charset=utf-8");
            assert_eq!(asset.cache_control, "no-cache");
        }

        for path in ["/share", "share", "/share.html", "share.html"] {
            let asset = get_web_asset(path).unwrap_or_else(|| panic!("failed for path: {path}"));
            assert_eq!(asset.bytes, SHARE_HTML);
            assert_eq!(asset.content_type, "text/html; charset=utf-8");
            assert_eq!(asset.cache_control, "no-cache");
        }
    }

    #[test]
    fn test_logo_svg() {
        for path in ["/logo.svg", "logo.svg", "/logo.svg?v=1"] {
            let asset = get_web_asset(path).unwrap_or_else(|| panic!("failed for path: {path}"));
            assert_eq!(asset.bytes, LOGO_SVG);
            assert_eq!(asset.content_type, "image/svg+xml");
            assert_eq!(asset.cache_control, "public, max-age=86400");
        }
    }

    #[test]
    fn test_hashed_js_and_css_bundles() {
        let js_asset = get_web_asset("/assets/main-D6MKEcMq.js").expect("main js missing");
        assert_eq!(js_asset.bytes, MAIN_JS);
        assert_eq!(js_asset.content_type, "application/javascript; charset=utf-8");
        assert_eq!(js_asset.cache_control, "public, max-age=31536000, immutable");

        let css_asset = get_web_asset("/assets/main-DO0WF65x.css").expect("main css missing");
        assert_eq!(css_asset.bytes, MAIN_CSS);
        assert_eq!(css_asset.content_type, "text/css; charset=utf-8");
        assert_eq!(css_asset.cache_control, "public, max-age=31536000, immutable");

        let dyn_js = get_web_asset("/assets/custom-bundle.js").expect("dyn js missing");
        assert_eq!(dyn_js.bytes, MAIN_JS);
        assert_eq!(dyn_js.cache_control, "public, max-age=31536000, immutable");

        let dyn_css = get_web_asset("/assets/custom-bundle.css").expect("dyn css missing");
        assert_eq!(dyn_css.bytes, MAIN_CSS);
        assert_eq!(dyn_css.cache_control, "public, max-age=31536000, immutable");
    }

    #[test]
    fn test_spa_routes_fallback() {
        for path in ["/instant", "/custom", "/login", "/qr", "instant", "/instant?user=alice", "/ui/settings"] {
            let asset = get_web_asset(path).unwrap_or_else(|| panic!("failed for path: {path}"));
            assert_eq!(asset.bytes, INDEX_HTML);
            assert_eq!(asset.content_type, "text/html; charset=utf-8");
            assert_eq!(asset.cache_control, "no-cache");
        }
    }

    #[test]
    fn test_none_for_api_and_unknown_extensions() {
        let none_paths = [
            "/api",
            "/api/",
            "/api/v1/foo",
            "/api/v1/accounts/instant",
            "/api/v1/accounts/custom",
            "/apps/xdcstore",
            "/apps/xdcstore/",
            "/apps/xdcstore/chess.xdc",
            "/missing.png",
            "/assets/missing.png",
            "/style.css",
            "/favicon.ico",
        ];

        for path in none_paths {
            assert!(
                get_web_asset(path).is_none(),
                "path should return None: {path}"
            );
        }
    }
}
