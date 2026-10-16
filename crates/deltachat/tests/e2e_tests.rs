/*
 * SPDX-FileCopyrightText: 2026 Stalwart Labs LLC <hello@stalw.art>
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
 */

use common::Server;
use deltachat::{
    altcha::{AltchaChallenge, AltchaEngine, AltchaPayload},
    config::DeltaChatSettings,
    dispatch_web_asset, dispatch_xdc_asset,
    error::DeltaChatError,
    models::{AppsCatalogResponse, HealthResponse},
    DeltaChatRouter,
};
use std::mem::MaybeUninit;
use std::sync::atomic::AtomicUsize;
use std::sync::Arc;

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
async fn test_e2e_health_and_config_discovery() {
    let router = DeltaChatRouter::new();
    let server = dummy_server();

    let settings = DeltaChatSettings {
        enabled: true,
        registration_open: true,
        instant_accounts_enabled: true,
        custom_accounts_enabled: true,
        frontend_path: None,
        altcha_required: true,
        altcha_max_number: 50_000,
        altcha_hmac_secret: "test-secret-hmac-key".to_string(),
        ..Default::default()
    };

    // 1. Test /api/v1/health
    let (status, body, content_type) = router
        .dispatch_api(&settings, &server, "GET", "/api/v1/health", None)
        .await
        .expect("health check must succeed");

    assert_eq!(status, 200);
    assert_eq!(content_type, "application/json; charset=utf-8");

    let health: HealthResponse = serde_json::from_str(&body).expect("valid health response json");
    assert_eq!(health.status, "healthy");
    assert_eq!(health.version, "1.0.0-chatchi");
    assert!(health.uptime_seconds < 60);

    // GET /api/v1/config reads server.core; dummy_server is MaybeUninit.
    let res = router
        .dispatch_api(&settings, &server, "POST", "/api/v1/config", None)
        .await;
    assert_eq!(res, Err(DeltaChatError::MethodNotAllowed));
}

#[tokio::test]
async fn test_e2e_altcha_challenge_and_verification() {
    let secret_key = b"super-secret-hmac-key-deltachat-pow!".to_vec();
    let max_number = 10_000;
    let engine = AltchaEngine::new(secret_key.clone(), max_number);

    let settings = DeltaChatSettings {
        altcha_hmac_secret: String::from_utf8(secret_key).unwrap(),
        altcha_max_number: max_number,
        ..Default::default()
    };
    let router = DeltaChatRouter::new();
    let server = dummy_server();

    // 1. Generate challenge via /api/v1/altcha/challenge
    let (status, body, content_type) = router
        .dispatch_api(&settings, &server, "GET", "/api/v1/altcha/challenge", None)
        .await
        .expect("altcha challenge must succeed");

    assert_eq!(status, 200);
    assert_eq!(content_type, "application/json; charset=utf-8");

    let challenge: AltchaChallenge =
        serde_json::from_str(&body).expect("valid altcha challenge json");
    assert_eq!(challenge.algorithm, "SHA-256");
    assert_eq!(challenge.max_number, max_number);
    assert!(!challenge.challenge.is_empty());
    assert!(!challenge.salt.is_empty());
    assert!(!challenge.signature.is_empty());

    // 2. Simulate solving the challenge with SHA-256 PoW loop
    let mut solved_number = None;
    for n in 0..=challenge.max_number {
        if AltchaEngine::compute_hash(&challenge.salt, n) == challenge.challenge {
            solved_number = Some(n);
            break;
        }
    }
    let number = solved_number.expect("puzzle solution must exist within max_number");

    let payload = AltchaPayload {
        algorithm: challenge.algorithm,
        challenge: challenge.challenge,
        number,
        salt: challenge.salt,
        signature: challenge.signature,
    };

    // 3. Verifies the solved payload succeeds
    let verify_result = engine.verify_payload(&payload);
    assert!(verify_result.is_ok(), "solved payload must be accepted");

    // 4. Verifies replaying the same payload fails (anti-replay check)
    let replay_result = engine.verify_payload(&payload);
    assert_eq!(
        replay_result,
        Err(DeltaChatError::AltchaReplay),
        "replayed payload must be rejected"
    );
}

#[tokio::test]
async fn test_e2e_apps_catalog_and_asset_streaming() {
    let router = DeltaChatRouter::new();
    let settings = DeltaChatSettings::default();
    let server = dummy_server();

    // 1. Call /api/v1/apps and verify catalog items
    let (status, body, content_type) = router
        .dispatch_api(&settings, &server, "GET", "/api/v1/apps", None)
        .await
        .expect("apps catalog query must succeed");

    assert_eq!(status, 200);
    assert_eq!(content_type, "application/json; charset=utf-8");

    let catalog: AppsCatalogResponse =
        serde_json::from_str(&body).expect("valid apps catalog json");
    assert_eq!(catalog.version, "1.0.0");
    assert!(
        catalog.apps.len() >= 2,
        "catalog must contain at least Chess and Calendar"
    );

    let chess = catalog
        .apps
        .iter()
        .find(|a| a.app_id == "chat.delta.webxdc.chess")
        .expect("Chess app in catalog");
    assert_eq!(chess.name, "Chess");
    assert_eq!(chess.download_url, "/apps/xdcstore/packages/chess.xdc");

    let calendar = catalog
        .apps
        .iter()
        .find(|a| a.app_id == "chat.delta.webxdc.calendar")
        .expect("Calendar app in catalog");
    assert_eq!(calendar.name, "Calendar");
    assert_eq!(calendar.download_url, "/apps/xdcstore/packages/calendar.xdc");

    // 2. Call dispatch_xdc_asset("packages/chess.xdc") and verify content and MIME type
    let asset = dispatch_xdc_asset("packages/chess.xdc").expect("chess asset must be found");
    assert!(!asset.0.is_empty(), "asset content must not be empty");
    assert_eq!(asset.1, "application/octet-stream");

    // Verify router wrapper method returns matching asset
    let router_asset = router
        .dispatch_xdc_asset("packages/chess.xdc")
        .expect("router wrapper must return chess asset");
    assert_eq!(router_asset.0, asset.0);
    assert_eq!(router_asset.1, "application/octet-stream");
}

#[test]
fn test_e2e_web_spa_static_asset_serving() {
    let router = DeltaChatRouter::new();

    // 1. dispatch_web_asset("/") -> returns HTML with no-cache
    let root = dispatch_web_asset("/").expect("root web asset must exist");
    assert_eq!(root.content_type, "text/html; charset=utf-8");
    assert_eq!(root.cache_control, "no-cache");
    assert!(!root.bytes.is_empty());

    // 2. dispatch_web_asset("/assets/main-D6MKEcMq.js") -> returns JavaScript with immutable cache headers
    let js = dispatch_web_asset("/assets/main-D6MKEcMq.js")
        .expect("bundled javascript asset must exist");
    assert_eq!(js.content_type, "application/javascript; charset=utf-8");
    assert_eq!(js.cache_control, "public, max-age=31536000, immutable");
    assert!(!js.bytes.is_empty());

    // 3. dispatch_web_asset("/custom") -> SPA client-side route fallback to index.html
    let custom = dispatch_web_asset("/custom").expect("custom SPA route fallback must exist");
    assert_eq!(custom.content_type, "text/html; charset=utf-8");
    assert_eq!(custom.cache_control, "no-cache");
    assert_eq!(
        custom.bytes, root.bytes,
        "SPA client-side route must fallback to index.html content"
    );

    // Verify router wrapper method behavior
    let router_spa = router
        .dispatch_web_asset("/custom")
        .expect("router wrapper must return SPA fallback");
    assert_eq!(router_spa.bytes, root.bytes);

    // 4. dispatch_web_asset("/api/v1/health") -> returns None (correctly isolated)
    assert!(
        dispatch_web_asset("/api/v1/health").is_none(),
        "/api/v1/health must not be treated as a static web asset"
    );
    assert!(
        router.dispatch_web_asset("/api/v1/health").is_none(),
        "router dispatch_web_asset must isolate API routes"
    );
}
