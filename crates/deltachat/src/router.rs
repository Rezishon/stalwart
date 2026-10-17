/*
 * SPDX-FileCopyrightText: 2026 Stalwart Labs LLC <hello@stalw.art>
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
 */

use crate::altcha::AltchaEngine;
use crate::assets::{WebAsset, get_web_asset};
use crate::catalog::CatalogStore;
use crate::config::{endpoints_from_settings, fill_empty_endpoint_hosts, DeltaChatSettings};
use crate::error::DeltaChatError;
use crate::password_hash::password_hash_algorithm_str;
use crate::handlers::{
    accounts::{handle_custom_account, handle_instant_account},
    apps::handle_get_apps,
    system::{handle_altcha_challenge, handle_config, handle_health},
};
use crate::models::{CustomAccountRequest, InstantAccountRequest};
use common::Server;
use std::sync::Arc;
use std::time::Instant;

fn json_ok<T: serde::Serialize>(
    status: u16,
    resp: &T,
) -> Result<(u16, String, &'static str), DeltaChatError> {
    let json = serde_json::to_string(resp).map_err(|e| DeltaChatError::Internal(e.to_string()))?;
    Ok((status, json, "application/json; charset=utf-8"))
}

#[derive(Clone)]
pub struct DeltaChatRouter {
    pub start_time: Instant,
    pub replay_cache: Arc<utils::cache::CacheWithTtl<Box<str>, bool>>,
    pub fallback_hmac_key: [u8; 32],
}

impl Default for DeltaChatRouter {
    fn default() -> Self {
        Self::new()
    }
}

impl DeltaChatRouter {
    pub fn new() -> Self {
        Self {
            start_time: Instant::now(),
            replay_cache: Arc::new(utils::cache::CacheWithTtl::new_estimated(
                10_000,
                4 * 1024 * 1024,
            )),
            fallback_hmac_key: store::rand::random(),
        }
    }

    pub fn with_start_time(start_time: Instant) -> Self {
        Self {
            start_time,
            replay_cache: Arc::new(utils::cache::CacheWithTtl::new_estimated(
                10_000,
                4 * 1024 * 1024,
            )),
            fallback_hmac_key: store::rand::random(),
        }
    }

    pub fn get_altcha_engine(&self, settings: &DeltaChatSettings) -> AltchaEngine {
        let key = if !settings.altcha_hmac_secret.is_empty() {
            settings.altcha_hmac_secret.as_bytes().to_vec()
        } else {
            self.fallback_hmac_key.to_vec()
        };
        AltchaEngine::with_cache(key, settings.altcha_max_number, self.replay_cache.clone())
    }

    async fn discovery_context(
        settings: &DeltaChatSettings,
        server: &Server,
    ) -> Result<(String, crate::config::EndpointsConfig, &'static str), DeltaChatError> {
        let mut endpoints = endpoints_from_settings(settings)?;
        let algo = password_hash_algorithm_str(server.core.network.security.password_hash_algorithm);
        if !settings.domain_id.is_valid() {
            fill_empty_endpoint_hosts(&mut endpoints, &server.core.email.default_domain_name);
            return Ok(("localhost".into(), endpoints, algo));
        }
        let domain = server
            .domain_by_id(settings.domain_id.document_id())
            .await
            .map_err(|e| DeltaChatError::Internal(e.to_string()))?
            .ok_or_else(|| DeltaChatError::InvalidDomain("Primary domain not found".into()))?;
        let name = domain
            .names
            .first()
            .map(|n| n.to_string())
            .ok_or_else(|| DeltaChatError::InvalidDomain("Primary domain has no name".into()))?;
        fill_empty_endpoint_hosts(&mut endpoints, &name);
        fill_empty_endpoint_hosts(&mut endpoints, &server.core.email.default_domain_name);
        Ok((name, endpoints, algo))
    }

    pub async fn dispatch_api(
        &self,
        settings: &DeltaChatSettings,
        server: &Arc<Server>,
        method: &str,
        path: &str,
        body: Option<&[u8]>,
    ) -> Result<(u16, String, &'static str), DeltaChatError> {
        if !settings.enabled {
            return Err(DeltaChatError::DeltaChatDisabled);
        }

        let clean = path.split('?').next().unwrap_or(path);
        let route = clean.trim_start_matches('/').trim_end_matches('/');

        match route {
            "api/v1/health" => {
                if !method.eq_ignore_ascii_case("GET") {
                    return Err(DeltaChatError::MethodNotAllowed);
                }
                let resp = handle_health(settings, self.start_time)?;
                json_ok(200, &resp)
            }
            "api/v1/config" => {
                if !method.eq_ignore_ascii_case("GET") {
                    return Err(DeltaChatError::MethodNotAllowed);
                }
                let altcha_engine = self.get_altcha_engine(settings);
                let (domain, endpoints, password_hash_algorithm) =
                    Self::discovery_context(settings, server).await?;
                let resp = handle_config(
                    settings,
                    &altcha_engine,
                    domain,
                    endpoints,
                    password_hash_algorithm,
                )?;
                json_ok(200, &resp)
            }
            "api/v1/altcha/challenge" => {
                if !method.eq_ignore_ascii_case("GET") {
                    return Err(DeltaChatError::MethodNotAllowed);
                }
                let altcha_engine = self.get_altcha_engine(settings);
                let resp = handle_altcha_challenge(settings, &altcha_engine)?;
                json_ok(200, &resp)
            }
            "api/v1/accounts/instant" => {
                if !method.eq_ignore_ascii_case("POST") {
                    return Err(DeltaChatError::MethodNotAllowed);
                }
                let altcha_engine = self.get_altcha_engine(settings);
                let req = match body {
                    Some(bytes) if !bytes.is_empty() => {
                        serde_json::from_slice::<InstantAccountRequest>(bytes)
                            .map_err(|e| DeltaChatError::BadRequest(e.to_string()))?
                    }
                    _ => InstantAccountRequest::default(),
                };
                let resp = handle_instant_account(settings, &altcha_engine, server, req).await?;
                json_ok(201, &resp)
            }
            "api/v1/accounts/custom" => {
                if !method.eq_ignore_ascii_case("POST") {
                    return Err(DeltaChatError::MethodNotAllowed);
                }
                let altcha_engine = self.get_altcha_engine(settings);
                let bytes = body.ok_or_else(|| DeltaChatError::BadRequest("Missing request body".to_string()))?;
                let req = serde_json::from_slice::<CustomAccountRequest>(bytes)
                    .map_err(|e| DeltaChatError::BadRequest(e.to_string()))?;
                let resp = handle_custom_account(settings, &altcha_engine, server, req).await?;
                json_ok(201, &resp)
            }
            "api/v1/apps" => {
                if !method.eq_ignore_ascii_case("GET") {
                    return Err(DeltaChatError::MethodNotAllowed);
                }
                let resp = handle_get_apps(settings)?;
                json_ok(200, &resp)
            }
            _ => Err(DeltaChatError::NotFound("Endpoint not found")),
        }
    }

    pub fn dispatch_xdc_asset(&self, path: &str) -> Option<(&'static [u8], &'static str)> {
        dispatch_xdc_asset(path)
    }

    pub fn dispatch_web_asset(&self, path: &str) -> Option<WebAsset> {
        dispatch_web_asset(path)
    }
}

pub fn dispatch_xdc_asset(path: &str) -> Option<(&'static [u8], &'static str)> {
    let clean = path.split('?').next().unwrap_or(path);
    let trimmed = clean.trim_start_matches('/');
    let relative = trimmed
        .strip_prefix("apps/xdcstore/")
        .unwrap_or(trimmed);
    CatalogStore::get_asset(relative)
}

pub fn dispatch_web_asset(path: &str) -> Option<WebAsset> {
    get_web_asset(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::MaybeUninit;
    use std::sync::atomic::AtomicUsize;

    fn dummy_server() -> Arc<Server> {
        #[repr(C)]
        struct ArcInner<T> {
            strong: AtomicUsize,
            weak: AtomicUsize,
            data: T,
        }
        let inner = Box::leak(Box::new(ArcInner {
            strong: AtomicUsize::new(2),
            weak: AtomicUsize::new(1),
            data: MaybeUninit::<Server>::uninit(),
        }));
        unsafe { Arc::from_raw(inner.data.as_ptr()) }
    }

    #[tokio::test]
    async fn test_dispatch_api_health() {
        let router = DeltaChatRouter::new();
        let settings = DeltaChatSettings::default();
        let server = dummy_server();

        let (status, body, content_type) = router
            .dispatch_api(&settings, &server, "GET", "/api/v1/health", None)
            .await
            .unwrap();

        assert_eq!(status, 200);
        assert_eq!(content_type, "application/json; charset=utf-8");
        assert!(body.contains("\"status\":\"healthy\""));
        assert!(body.contains("\"version\":\"1.0.0-chatchi\""));

        // Wrong method
        let res = router
            .dispatch_api(&settings, &server, "POST", "/api/v1/health", None)
            .await;
        assert_eq!(res, Err(DeltaChatError::MethodNotAllowed));
    }

    #[tokio::test]
    async fn test_dispatch_api_config() {
        let router = DeltaChatRouter::new();
        let settings = DeltaChatSettings::default();
        let server = dummy_server();

        let res = router
            .dispatch_api(&settings, &server, "POST", "/api/v1/config", None)
            .await;
        assert_eq!(res, Err(DeltaChatError::MethodNotAllowed));
    }

    #[tokio::test]
    async fn test_dispatch_api_altcha_challenge() {
        let router = DeltaChatRouter::new();
        let settings = DeltaChatSettings::default();
        let server = dummy_server();

        let (status, body, content_type) = router
            .dispatch_api(&settings, &server, "GET", "/api/v1/altcha/challenge", None)
            .await
            .unwrap();

        assert_eq!(status, 200);
        assert_eq!(content_type, "application/json; charset=utf-8");
        assert!(body.contains("\"algorithm\":\"SHA-256\""));
        assert!(body.contains("\"challenge\""));
        assert!(body.contains("\"max_number\":100000"));
    }

    #[tokio::test]
    async fn test_dispatch_api_apps() {
        let router = DeltaChatRouter::new();
        let settings = DeltaChatSettings::default();
        let server = dummy_server();

        let (status, body, content_type) = router
            .dispatch_api(&settings, &server, "GET", "/api/v1/apps", None)
            .await
            .unwrap();

        assert_eq!(status, 200);
        assert_eq!(content_type, "application/json; charset=utf-8");
        assert!(body.contains("\"apps\""));
        assert!(body.contains("chat.delta.webxdc.chess"));
        assert!(body.contains("chat.delta.webxdc.calendar"));
    }

    #[tokio::test]
    async fn test_dispatch_api_disabled() {
        let router = DeltaChatRouter::new();
        let settings = DeltaChatSettings {
            enabled: false,
            ..Default::default()
        };
        let server = dummy_server();

        let res = router
            .dispatch_api(&settings, &server, "GET", "/api/v1/health", None)
            .await;
        assert_eq!(res, Err(DeltaChatError::DeltaChatDisabled));

        let res = router
            .dispatch_api(&settings, &server, "GET", "/api/v1/config", None)
            .await;
        assert_eq!(res, Err(DeltaChatError::DeltaChatDisabled));
    }

    #[tokio::test]
    async fn test_dispatch_api_not_found() {
        let router = DeltaChatRouter::new();
        let settings = DeltaChatSettings::default();
        let server = dummy_server();

        let res = router
            .dispatch_api(&settings, &server, "GET", "/api/v1/unknown", None)
            .await;
        assert_eq!(res, Err(DeltaChatError::NotFound("Endpoint not found")));
    }

    #[test]
    fn test_dispatch_xdc_asset() {
        // Direct package name
        let asset = dispatch_xdc_asset("chess.xdc").expect("chess.xdc asset");
        assert_eq!(asset.1, "application/octet-stream");

        // With /apps/xdcstore/ prefix
        let asset = dispatch_xdc_asset("/apps/xdcstore/chess.xdc").expect("/apps/xdcstore/chess.xdc");
        assert_eq!(asset.1, "application/octet-stream");

        // With packages/ path
        let asset = dispatch_xdc_asset("/apps/xdcstore/packages/chess.xdc").expect("packages/chess.xdc");
        assert_eq!(asset.1, "application/octet-stream");

        // Icon asset
        let icon = dispatch_xdc_asset("/apps/xdcstore/icons/chess.png").expect("chess.png");
        assert_eq!(icon.1, "image/png");

        // Unknown asset
        assert!(dispatch_xdc_asset("unknown.xdc").is_none());
    }

    #[test]
    fn test_dispatch_web_asset() {
        // Root paths
        let root = dispatch_web_asset("/").expect("root asset");
        assert_eq!(root.content_type, "text/html; charset=utf-8");

        let empty = dispatch_web_asset("").expect("empty asset");
        assert_eq!(empty.content_type, "text/html; charset=utf-8");

        let index = dispatch_web_asset("/index.html").expect("index.html");
        assert_eq!(index.content_type, "text/html; charset=utf-8");

        // SPA HTML paths
        let apps = dispatch_web_asset("/apps").expect("apps SPA route");
        assert_eq!(apps.content_type, "text/html; charset=utf-8");

        let docs = dispatch_web_asset("/docs").expect("docs SPA route");
        assert_eq!(docs.content_type, "text/html; charset=utf-8");

        let login = dispatch_web_asset("/login").expect("login fallback SPA route");
        assert_eq!(login.content_type, "text/html; charset=utf-8");

        // Non-web / API paths should not be intercepted as web assets
        assert!(dispatch_web_asset("/api/v1/health").is_none());
        assert!(dispatch_web_asset("/apps/xdcstore/packages/chess.xdc").is_none());
    }
}
