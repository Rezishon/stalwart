/*
 * SPDX-FileCopyrightText: 2026 Stalwart Labs LLC <hello@stalw.art>
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
 */

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct InstantAccountRequest {
    #[serde(default)]
    pub altcha_payload: Option<String>,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InstantAccountResponse {
    pub account_id: String,
    pub email: String,
    pub password: String,
    pub dclogin_link: String,
    pub account_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<String>,
}

impl std::fmt::Debug for InstantAccountResponse {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("InstantAccountResponse")
            .field("account_id", &self.account_id)
            .field("email", &self.email)
            .field("password", &"[REDACTED]")
            .field("dclogin_link", &"[REDACTED]")
            .field("account_type", &self.account_type)
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CustomAccountRequest {
    pub username: String,
    pub password: String,
    #[serde(default)]
    pub altcha_payload: Option<String>,
}

impl std::fmt::Debug for CustomAccountRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CustomAccountRequest")
            .field("username", &self.username)
            .field("password", &"[REDACTED]")
            .field("altcha_payload", &self.altcha_payload)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CustomAccountResponse {
    pub account_id: String,
    pub email: String,
    pub dclogin_link: String,
    pub account_type: String,
}

impl std::fmt::Debug for CustomAccountResponse {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CustomAccountResponse")
            .field("account_id", &self.account_id)
            .field("email", &self.email)
            .field("dclogin_link", &"[REDACTED]")
            .field("account_type", &self.account_type)
            .finish()
    }
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
            password: "super_secret_password".into(),
            altcha_payload: None,
        };
        let debug_str = format!("{req:?}");
        assert!(!debug_str.contains("super_secret_password"));
        assert!(debug_str.contains("[REDACTED]"));

        let resp = InstantAccountResponse {
            account_id: "acc_123".into(),
            email: "alice@domain.org".into(),
            password: "plain_password".into(),
            dclogin_link: "dclogin:alice@domain.org".into(),
            account_type: "instant".into(),
            expires_at: None,
        };
        let resp_debug = format!("{resp:?}");
        assert!(!resp_debug.contains("plain_password"));
        assert!(!resp_debug.contains("dclogin:alice@domain.org"));
        assert!(resp_debug.contains("[REDACTED]"));

        let custom_resp = CustomAccountResponse {
            account_id: "acc_456".into(),
            email: "bob@domain.org".into(),
            dclogin_link: "dclogin:bob@domain.org/?p=secret".into(),
            account_type: "custom".into(),
        };
        let custom_debug = format!("{custom_resp:?}");
        assert!(!custom_debug.contains("secret"));
        assert!(custom_debug.contains("[REDACTED]"));
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
