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
    Default,
    Plain,
}

impl EndpointSecurity {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Ssl => "ssl",
            Self::Starttls => "starttls",
            Self::Default => "default",
            Self::Plain => "plain",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum CertificateChecks {
    Automatic = 0,
    Strict = 1,
    #[default]
    AcceptInvalid = 3,
}

impl CertificateChecks {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Automatic => "0",
            Self::Strict => "1",
            Self::AcceptInvalid => "3",
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
        EndpointsConfig {
            imap: MailEndpointConfig {
                host: "localhost".into(),
                port: 993,
                security: EndpointSecurity::Ssl,
            },
            smtp: MailEndpointConfig {
                host: "localhost".into(),
                port: 465,
                security: EndpointSecurity::Ssl,
            },
        }
    }

    pub fn advertised_endpoints(server: &Server) -> EndpointsConfig {
        let default_host = if server.core.network.server_name.is_empty() {
            "localhost"
        } else {
            server.core.network.server_name.as_str()
        };
        EndpointsConfig {
            imap: advertised_mail_endpoint(server, ServiceProtocol::Imap, default_host, 993),
            smtp: advertised_mail_endpoint(server, ServiceProtocol::Smtp, default_host, 465),
        }
    }
}

fn advertised_mail_endpoint(
    server: &Server,
    protocol: ServiceProtocol,
    default_host: &str,
    port: u16,
) -> MailEndpointConfig {
    let host = server
        .core
        .network
        .info
        .services
        .get(&protocol)
        .and_then(|s| s.hostname.as_deref())
        .unwrap_or(default_host)
        .to_string();
    MailEndpointConfig {
        host,
        port,
        security: EndpointSecurity::Ssl,
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
    fn security_and_ic_round_trip_as_dclogin_tokens() {
        assert_eq!(EndpointSecurity::Starttls.as_str(), "starttls");
        assert_eq!(EndpointSecurity::Plain.as_str(), "plain");
        assert_eq!(EndpointSecurity::Default.as_str(), "default");
        assert_eq!(CertificateChecks::Strict.as_str(), "1");
        assert_eq!(CertificateChecks::Automatic.as_str(), "0");
        assert_eq!(CertificateChecks::AcceptInvalid.as_str(), "3");
    }
}
