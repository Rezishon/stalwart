/*
 * SPDX-FileCopyrightText: 2026 Stalwart Labs LLC <hello@stalw.art>
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
 */

use crate::models::{AppsCatalogResponse, WebXdcApp};

pub struct CatalogStore;

impl CatalogStore {
    pub fn get_catalog() -> AppsCatalogResponse {
        AppsCatalogResponse {
            version: "1.0.0".to_string(),
            apps: vec![
                WebXdcApp {
                    app_id: "chat.delta.webxdc.chess".to_string(),
                    name: "Chess".to_string(),
                    version: "1.4.2".to_string(),
                    description: "Play chess peer-to-peer with contacts in DeltaChat".to_string(),
                    size: 420_000,
                    icon_url: "/apps/xdcstore/icons/chess.png".to_string(),
                    download_url: "/apps/xdcstore/packages/chess.xdc".to_string(),
                },
                WebXdcApp {
                    app_id: "chat.delta.webxdc.calendar".to_string(),
                    name: "Calendar".to_string(),
                    version: "1.0.1".to_string(),
                    description: "Share and manage events directly in chat".to_string(),
                    size: 280_000,
                    icon_url: "/apps/xdcstore/icons/calendar.png".to_string(),
                    download_url: "/apps/xdcstore/packages/calendar.xdc".to_string(),
                },
            ],
        }
    }

    pub fn get_asset(path: &str) -> Option<(&'static [u8], &'static str)> {
        static DUMMY_XDC: &[u8] = b"PK\x05\x06\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0";
        match path {
            "chess.xdc" | "packages/chess.xdc" => {
                Some((DUMMY_XDC, "application/octet-stream"))
            }
            "calendar.xdc" | "packages/calendar.xdc" => {
                Some((DUMMY_XDC, "application/octet-stream"))
            }
            "chess.png" | "icons/chess.png" => {
                Some((b"\x89PNG\r\n\x1a\n", "image/png"))
            }
            "calendar.png" | "icons/calendar.png" => {
                Some((b"\x89PNG\r\n\x1a\n", "image/png"))
            }
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_catalog_store_default() {
        let catalog = CatalogStore::get_catalog();
        assert_eq!(catalog.version, "1.0.0");
        assert_eq!(catalog.apps.len(), 2);
        assert_eq!(catalog.apps[0].app_id, "chat.delta.webxdc.chess");
    }

    #[test]
    fn test_catalog_store_asset() {
        let asset = CatalogStore::get_asset("packages/chess.xdc");
        assert!(asset.is_some());
        assert_eq!(asset.unwrap().1, "application/octet-stream");

        let missing = CatalogStore::get_asset("unknown.xdc");
        assert!(missing.is_none());
    }
}
