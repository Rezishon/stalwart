/*
 * SPDX-FileCopyrightText: 2026 Stalwart Labs LLC <hello@stalw.art>
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
 */

use super::application::{rewrite_index, AppResource, Resource};

include!(concat!(env!("OUT_DIR"), "/webui_embed.rs"));

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EmbeddedAsset {
    pub bytes: &'static [u8],
    pub content_type: &'static str,
}

pub fn get_webui(path: &str) -> Option<EmbeddedAsset> {
    let clean = path.split('?').next().unwrap_or(path);
    let trimmed = clean.trim_matches('/');

    if let Some((bytes, content_type)) = lookup(trimmed) {
        return Some(EmbeddedAsset {
            bytes,
            content_type,
        });
    }
    if trimmed.is_empty() {
        return lookup("index.html").map(|(bytes, content_type)| EmbeddedAsset {
            bytes,
            content_type,
        });
    }
    let last = trimmed.rsplit('/').next().unwrap_or(trimmed);
    if !last.contains('.') {
        lookup("index.html").map(|(bytes, content_type)| EmbeddedAsset {
            bytes,
            content_type,
        })
    } else {
        None
    }
}

pub fn serve_embedded_webui(prefix: &str, path: &str) -> Option<AppResource> {
    let asset = get_webui(path)?;
    let is_index = asset.content_type == "text/html";
    let contents = if is_index {
        if let Ok(html) = std::str::from_utf8(asset.bytes) {
            rewrite_index(html, prefix, None)
        } else {
            asset.bytes.to_vec()
        }
    } else {
        asset.bytes.to_vec()
    };
    Some(AppResource {
        resource: Resource {
            content_type: asset.content_type.into(),
            contents,
        },
        no_cache: is_index,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn webui_index_and_hashed_asset() {
        let idx = get_webui("/").expect("index");
        assert_eq!(idx.content_type, "text/html");
        assert!(idx.bytes.starts_with(b"<!"), "index should be html");
        let ico = get_webui("favicon.ico").expect("favicon");
        assert_eq!(ico.content_type, "image/x-icon");
        assert!(get_webui("nope.png").is_none());
        assert!(get_webui("/admin").is_some());
    }

    #[test]
    fn serve_rewrites_base_href() {
        let served = serve_embedded_webui("admin", "index.html").expect("index");
        assert!(served.no_cache);
        let html = String::from_utf8(served.resource.contents).unwrap();
        assert!(html.contains("<base href=\"/admin/\""), "{html}");
    }

    #[test]
    fn version_has_rl_suffix() {
        assert!(
            crate::VERSION_PRIVATE.contains("-rl"),
            "{}",
            crate::VERSION_PRIVATE
        );
    }
}
