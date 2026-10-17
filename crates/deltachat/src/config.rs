/*
 * SPDX-FileCopyrightText: 2026 Stalwart Labs LLC <hello@stalw.art>
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
 */

use crate::error::DeltaChatError;
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
    pub imap: MailEndpointConfig,
    pub smtp: MailEndpointConfig,
    pub certificate_checks: CertificateChecks,
    pub instant_prefix_enabled: bool,
    pub instant_prefix: String,
    pub custom_prefix_enabled: bool,
    pub custom_prefix: String,
    pub username_blacklist: Vec<String>,
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
            imap: MailEndpointConfig {
                host: String::new(),
                port: 993,
                security: EndpointSecurity::Ssl,
            },
            smtp: MailEndpointConfig {
                host: String::new(),
                port: 465,
                security: EndpointSecurity::Ssl,
            },
            certificate_checks: CertificateChecks::AcceptInvalid,
            instant_prefix_enabled: true,
            instant_prefix: "dc_".into(),
            custom_prefix_enabled: false,
            custom_prefix: String::new(),
            username_blacklist: registry::schema::structs_impl::DEFAULT_USERNAME_BLACKLIST
                .iter()
                .map(|s| s.to_string())
                .collect(),
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

    #[cfg(test)]
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
}

pub fn endpoints_from_settings(settings: &DeltaChatSettings) -> Result<EndpointsConfig, DeltaChatError> {
    Ok(EndpointsConfig {
        imap: settings.imap.clone(),
        smtp: settings.smtp.clone(),
    })
}

pub fn fill_empty_endpoint_hosts(endpoints: &mut EndpointsConfig, domain: &str) {
    let domain = domain.trim();
    if domain.is_empty() || domain == "localhost" || domain == "localhost.local" {
        return;
    }
    if endpoints.imap.host.trim().is_empty() {
        endpoints.imap.host = domain.to_string();
    }
    if endpoints.smtp.host.trim().is_empty() {
        endpoints.smtp.host = domain.to_string();
    }
}

fn parse_security(s: &str) -> EndpointSecurity {
    match s {
        "starttls" => EndpointSecurity::Starttls,
        "default" => EndpointSecurity::Default,
        "plain" => EndpointSecurity::Plain,
        _ => EndpointSecurity::Ssl,
    }
}

fn parse_ic(s: &str) -> CertificateChecks {
    match s {
        "0" => CertificateChecks::Automatic,
        "1" => CertificateChecks::Strict,
        _ => CertificateChecks::AcceptInvalid,
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
            imap: MailEndpointConfig {
                host: c.imap_host,
                port: u16::try_from(c.imap_port).unwrap_or(993),
                security: parse_security(&c.imap_security),
            },
            smtp: MailEndpointConfig {
                host: c.smtp_host,
                port: u16::try_from(c.smtp_port).unwrap_or(465),
                security: parse_security(&c.smtp_security),
            },
            certificate_checks: parse_ic(&c.certificate_checks),
            instant_prefix_enabled: c.instant_prefix_enabled,
            instant_prefix: c.instant_prefix,
            custom_prefix_enabled: c.custom_prefix_enabled,
            custom_prefix: c.custom_prefix,
            username_blacklist: c
                .username_blacklist
                .into_inner()
                .into_iter()
                .map(|s| s.to_ascii_lowercase())
                .collect(),
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
        assert!(settings.instant_prefix_enabled);
        assert_eq!(settings.instant_prefix, "dc_");
        assert!(!settings.custom_prefix_enabled);
        assert_eq!(settings.custom_prefix, "");
        assert_eq!(
            settings.username_blacklist,
            registry::schema::structs_impl::DEFAULT_USERNAME_BLACKLIST
        );
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

    #[test]
    fn empty_hosts_fill_from_primary_domain() {
        let mut endpoints = EndpointsConfig {
            imap: MailEndpointConfig {
                host: String::new(),
                port: 993,
                security: EndpointSecurity::Ssl,
            },
            smtp: MailEndpointConfig {
                host: String::new(),
                port: 465,
                security: EndpointSecurity::Ssl,
            },
        };
        fill_empty_endpoint_hosts(&mut endpoints, "example.org");
        assert_eq!(endpoints.imap.host, "example.org");
        assert_eq!(endpoints.smtp.host, "example.org");
    }

    #[test]
    fn saved_host_is_not_overwritten() {
        let mut endpoints = EndpointsConfig {
            imap: MailEndpointConfig {
                host: "imap.custom".into(),
                port: 993,
                security: EndpointSecurity::Ssl,
            },
            smtp: MailEndpointConfig {
                host: String::new(),
                port: 465,
                security: EndpointSecurity::Ssl,
            },
        };
        fill_empty_endpoint_hosts(&mut endpoints, "example.org");
        assert_eq!(endpoints.imap.host, "imap.custom");
        assert_eq!(endpoints.smtp.host, "example.org");
    }

    #[test]
    fn empty_domain_does_not_fill_hosts() {
        let mut endpoints = EndpointsConfig {
            imap: MailEndpointConfig {
                host: String::new(),
                port: 993,
                security: EndpointSecurity::Ssl,
            },
            smtp: MailEndpointConfig {
                host: "smtp.custom".into(),
                port: 465,
                security: EndpointSecurity::Ssl,
            },
        };
        fill_empty_endpoint_hosts(&mut endpoints, "");
        assert!(endpoints.imap.host.is_empty());
        assert_eq!(endpoints.smtp.host, "smtp.custom");
    }

    #[test]
    fn dummy_localhost_does_not_fill_hosts() {
        let mut endpoints = EndpointsConfig {
            imap: MailEndpointConfig {
                host: String::new(),
                port: 993,
                security: EndpointSecurity::Ssl,
            },
            smtp: MailEndpointConfig {
                host: String::new(),
                port: 465,
                security: EndpointSecurity::Ssl,
            },
        };
        fill_empty_endpoint_hosts(&mut endpoints, "localhost");
        fill_empty_endpoint_hosts(&mut endpoints, "localhost.local");
        assert!(endpoints.imap.host.is_empty());
        assert!(endpoints.smtp.host.is_empty());
    }

    #[test]
    fn null_imap_host_does_not_require_smtp_host() {
        let c: registry::schema::structs::DeltaChat =
            serde_json::from_str(r#"{"imapHost":null,"smtpHost":"smtp.example.org"}"#).unwrap();
        assert_eq!(c.imap_host, "");
        assert_eq!(c.smtp_host, "smtp.example.org");
    }

    #[test]
    fn null_smtp_host_does_not_require_imap_host() {
        let c: registry::schema::structs::DeltaChat =
            serde_json::from_str(r#"{"imapHost":"imap.example.org","smtpHost":null}"#).unwrap();
        assert_eq!(c.imap_host, "imap.example.org");
        assert_eq!(c.smtp_host, "");
    }

    #[test]
    fn test_settings_from_registry_prefixes_and_blacklist() {
        let reg = registry::schema::structs::DeltaChat {
            instant_prefix_enabled: true,
            instant_prefix: "custom_dc_".into(),
            custom_prefix_enabled: true,
            custom_prefix: "usr_".into(),
            username_blacklist: registry::types::map::Map::new(vec!["BadUser".to_string()]),
            ..Default::default()
        };

        let settings = DeltaChatSettings::from(reg);
        assert!(settings.instant_prefix_enabled);
        assert_eq!(settings.instant_prefix, "custom_dc_");
        assert!(settings.custom_prefix_enabled);
        assert_eq!(settings.custom_prefix, "usr_");
        assert_eq!(settings.username_blacklist, vec!["baduser"]);
    }
}
