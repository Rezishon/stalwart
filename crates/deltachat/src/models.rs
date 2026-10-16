/*
 * SPDX-FileCopyrightText: 2026 Stalwart Labs LLC <hello@stalw.art>
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
 */

use serde::{Deserialize, Serialize};

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct InstantAccountRequest {
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub password_hash: String,
    #[serde(default)]
    pub altcha_payload: Option<String>,
    #[serde(default)]
    pub password: Option<String>,
}

impl std::fmt::Debug for InstantAccountRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("InstantAccountRequest")
            .field("username", &self.username)
            .field("password_hash", &"[REDACTED]")
            .field("altcha_payload", &self.altcha_payload)
            .field("password", &self.password.as_ref().map(|_| "[REDACTED]"))
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InstantAccountResponse {
    pub account_id: String,
    pub email: String,
    pub account_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<String>,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CustomAccountRequest {
    pub username: String,
    #[serde(default)]
    pub password_hash: String,
    #[serde(default)]
    pub altcha_payload: Option<String>,
    #[serde(default)]
    pub password: Option<String>,
}

impl std::fmt::Debug for CustomAccountRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CustomAccountRequest")
            .field("username", &self.username)
            .field("password_hash", &"[REDACTED]")
            .field("altcha_payload", &self.altcha_payload)
            .field("password", &self.password.as_ref().map(|_| "[REDACTED]"))
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CustomAccountResponse {
    pub account_id: String,
    pub email: String,
    pub account_type: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WebXdcApp {
    pub app_id: String,
    pub name: String,
    pub version: String,
    pub description: String,
    pub size: u64,
    pub icon_url: String,
    pub download_url: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppsCatalogResponse {
    pub version: String,
    pub apps: Vec<WebXdcApp>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HealthResponse {
    pub status: String,
    pub version: String,
    pub uptime_seconds: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConfigDiscoveryEndpoints {
    pub imap: ConfigDiscoveryMailEndpoint,
    pub smtp: ConfigDiscoveryMailEndpoint,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConfigDiscoveryMailEndpoint {
    pub host: String,
    pub port: u16,
    pub security: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConfigDiscoveryAltcha {
    pub required: bool,
    pub max_number: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub challenge: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConfigDiscoveryResponse {
    pub domain: String,
    pub registration_open: bool,
    pub instant_accounts_enabled: bool,
    pub custom_accounts_enabled: bool,
    pub endpoints: ConfigDiscoveryEndpoints,
    pub altcha: ConfigDiscoveryAltcha,
    pub password_hash_algorithm: String,
    pub certificate_checks: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_secret_redaction_debug() {
        let req = CustomAccountRequest {
            username: "alice".into(),
            password_hash: "super_secret_password".into(),
            altcha_payload: None,
            password: Some("plain".into()),
        };
        let debug_str = format!("{req:?}");
        assert!(!debug_str.contains("super_secret_password"));
        assert!(!debug_str.contains("plain"));
        assert!(debug_str.contains("[REDACTED]"));

        let resp = InstantAccountResponse {
            account_id: "acc_123".into(),
            email: "alice@domain.org".into(),
            account_type: "instant".into(),
            expires_at: None,
        };
        let resp_debug = format!("{resp:?}");
        assert!(resp_debug.contains("alice@domain.org"));

        let custom_resp = CustomAccountResponse {
            account_id: "acc_456".into(),
            email: "bob@domain.org".into(),
            account_type: "custom".into(),
        };
        let custom_debug = format!("{custom_resp:?}");
        assert!(custom_debug.contains("bob@domain.org"));
    }

    #[test]
    fn test_models_serde() {
        let health = HealthResponse {
            status: "healthy".into(),
            version: "1.0.0".into(),
            uptime_seconds: 42,
        };
        let json = serde_json::to_string(&health).unwrap();
        assert!(json.contains("\"status\":\"healthy\""));
    }
}
