/*
 * SPDX-FileCopyrightText: 2026 Stalwart Labs LLC <hello@stalw.art>
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
 */

use common::Server;
use registry::schema::enums::ServiceProtocol;
use serde::{Deserialize, Serialize};
use types::id::Id;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum EndpointSecurity {
    #[default]
    Ssl,
    Starttls,
    Plain,
}

impl EndpointSecurity {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Ssl => "ssl",
            Self::Starttls => "starttls",
            Self::Plain => "plain",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MailEndpointConfig {
    pub host: String,
    pub port: u16,
    pub security: EndpointSecurity,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EndpointsConfig {
    pub imap: MailEndpointConfig,
    pub smtp: MailEndpointConfig,
    pub ic: u8,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AltchaSettings {
    pub required: bool,
    pub max_number: u64,
    pub hmac_secret: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DeltaChatSettings {
    pub enabled: bool,
    pub registration_open: bool,
    pub instant_accounts_enabled: bool,
    pub custom_accounts_enabled: bool,
    pub frontend_path: Option<String>,
    pub domain_id: Id,
    pub allowed_domains: Vec<Id>,
    pub altcha_required: bool,
    pub altcha_max_number: u64,
    pub altcha_hmac_secret: String,
}

impl Default for DeltaChatSettings {
    fn default() -> Self {
        Self {
            enabled: true,
            registration_open: true,
            instant_accounts_enabled: true,
            custom_accounts_enabled: true,
            frontend_path: None,
            domain_id: Id::default(),
            allowed_domains: Vec::new(),
            altcha_required: false,
            altcha_max_number: 100_000,
            altcha_hmac_secret: String::new(),
        }
    }
}

impl DeltaChatSettings {
    pub fn is_domain_id_allowed(&self, domain_id: u32) -> bool {
        let id = Id::from(domain_id);
        if self.domain_id == id {
            return true;
        }
        self.allowed_domains.contains(&id)
    }

    pub fn resolved_altcha_hmac_key(&self) -> Vec<u8> {
        self.altcha_hmac_secret.as_bytes().to_vec()
    }

    pub fn default_endpoints() -> EndpointsConfig {
        endpoints_from_env("localhost", None)
    }

    pub fn advertised_endpoints(server: &Server) -> EndpointsConfig {
        let default_host = if server.core.network.server_name.is_empty() {
            "localhost"
        } else {
            server.core.network.server_name.as_str()
        };
        endpoints_from_env(default_host, Some(server))
    }
}

fn env_mail(new: &str, old: &str) -> Option<String> {
    std::env::var(new).or_else(|_| std::env::var(old)).ok()
}

fn env_tls_on() -> bool {
    match env_mail("MAILIAM_TLS", "STALWART_TLS") {
        Some(raw) => matches!(raw.to_ascii_lowercase().as_str(), "1" | "true"),
        None => true,
    }
}

fn parse_dc_port(raw: Option<&str>, tls_default: u16, plain_default: u16, tls: bool) -> u16 {
    match raw.and_then(|s| s.parse::<u16>().ok()).filter(|&p| p != 0) {
        Some(p) => p,
        None if tls => tls_default,
        None => plain_default,
    }
}

fn parse_dc_security(raw: Option<&str>, tls: bool) -> EndpointSecurity {
    match raw.map(|s| s.to_ascii_lowercase()).as_deref() {
        Some("ssl") => EndpointSecurity::Ssl,
        Some("starttls") => EndpointSecurity::Starttls,
        Some("plain") => EndpointSecurity::Plain,
        _ if tls => EndpointSecurity::Ssl,
        _ => EndpointSecurity::Plain,
    }
}

fn parse_dc_ic(raw: Option<&str>, tls: bool) -> u8 {
    match raw {
        Some("0") => 0,
        Some("1") => 1,
        Some("3") => 3,
        _ if tls => 3,
        _ => 0,
    }
}

fn endpoints_from_env(default_host: &str, server: Option<&Server>) -> EndpointsConfig {
    let tls = env_tls_on();
    let imap_host = env_mail("MAILIAM_DC_IMAP_HOST", "STALWART_DC_IMAP_HOST")
        .filter(|s| !s.is_empty())
        .or_else(|| {
            server.and_then(|s| {
                s.core
                    .network
                    .info
                    .services
                    .get(&ServiceProtocol::Imap)
                    .and_then(|svc| svc.hostname.clone())
            })
        })
        .unwrap_or_else(|| default_host.to_string());
    let smtp_host = env_mail("MAILIAM_DC_SMTP_HOST", "STALWART_DC_SMTP_HOST")
        .filter(|s| !s.is_empty())
        .or_else(|| {
            server.and_then(|s| {
                s.core
                    .network
                    .info
                    .services
                    .get(&ServiceProtocol::Smtp)
                    .and_then(|svc| svc.hostname.clone())
            })
        })
        .unwrap_or_else(|| default_host.to_string());
    EndpointsConfig {
        imap: MailEndpointConfig {
            host: imap_host,
            port: parse_dc_port(
                env_mail("MAILIAM_DC_IMAP_PORT", "STALWART_DC_IMAP_PORT").as_deref(),
                993,
                143,
                tls,
            ),
            security: parse_dc_security(
                env_mail("MAILIAM_DC_IMAP_SECURITY", "STALWART_DC_IMAP_SECURITY").as_deref(),
                tls,
            ),
        },
        smtp: MailEndpointConfig {
            host: smtp_host,
            port: parse_dc_port(
                env_mail("MAILIAM_DC_SMTP_PORT", "STALWART_DC_SMTP_PORT").as_deref(),
                465,
                587,
                tls,
            ),
            security: parse_dc_security(
                env_mail("MAILIAM_DC_SMTP_SECURITY", "STALWART_DC_SMTP_SECURITY").as_deref(),
                tls,
            ),
        },
        ic: parse_dc_ic(env_mail("MAILIAM_DC_IC", "STALWART_DC_IC").as_deref(), tls),
    }
}

impl From<registry::schema::structs::DeltaChat> for DeltaChatSettings {
    fn from(c: registry::schema::structs::DeltaChat) -> Self {
        Self {
            enabled: c.enabled,
            registration_open: c.registration_open,
            instant_accounts_enabled: c.instant_accounts_enabled,
            custom_accounts_enabled: c.custom_accounts_enabled,
            frontend_path: c.frontend_path,
            domain_id: c.domain_id,
            allowed_domains: c.allowed_domains.into_inner(),
            altcha_required: c.altcha_required,
            altcha_max_number: c.altcha_max_number,
            altcha_hmac_secret: c.altcha_hmac_secret,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_settings() {
        let settings = DeltaChatSettings::default();
        assert!(settings.enabled);
        assert!(!settings.domain_id.is_valid());
        assert!(settings.allowed_domains.is_empty());
        assert!(!settings.altcha_required);
    }

    #[test]
    fn test_domain_id_allowed() {
        let primary = Id::from(1u32);
        let extra = Id::from(2u32);
        let settings = DeltaChatSettings {
            domain_id: primary,
            allowed_domains: vec![extra],
            ..Default::default()
        };
        assert!(settings.is_domain_id_allowed(1));
        assert!(settings.is_domain_id_allowed(2));
        assert!(!settings.is_domain_id_allowed(3));
    }

    #[test]
    fn dc_port_security_ic_from_raw() {
        assert_eq!(parse_dc_port(None, 993, 143, true), 993);
        assert_eq!(parse_dc_port(None, 993, 143, false), 143);
        assert_eq!(parse_dc_port(Some("0"), 993, 143, true), 993);
        assert_eq!(parse_dc_port(Some("1143"), 993, 143, true), 1143);
        assert_eq!(parse_dc_security(None, true), EndpointSecurity::Ssl);
        assert_eq!(parse_dc_security(None, false), EndpointSecurity::Plain);
        assert_eq!(
            parse_dc_security(Some("STARTTLS"), true),
            EndpointSecurity::Starttls
        );
        assert_eq!(parse_dc_ic(None, true), 3);
        assert_eq!(parse_dc_ic(None, false), 0);
        assert_eq!(parse_dc_ic(Some("1"), false), 1);
    }
}
