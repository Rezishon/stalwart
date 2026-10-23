/*
 * SPDX-FileCopyrightText: 2026 Stalwart Labs LLC <hello@stalw.art>
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
 */

use crate::altcha::{AltchaChallenge, AltchaEngine};
use crate::config::{DeltaChatSettings, EndpointsConfig};
use crate::error::DeltaChatError;
use crate::models::{
    ConfigDiscoveryAltcha, ConfigDiscoveryEndpoints, ConfigDiscoveryMailEndpoint,
    ConfigDiscoveryResponse, HealthResponse, PlatformNameConfig,
};
use std::time::Instant;

pub fn handle_health(
    settings: &DeltaChatSettings,
    start_time: Instant,
) -> Result<HealthResponse, DeltaChatError> {
    if !settings.enabled {
        return Err(DeltaChatError::DeltaChatDisabled);
    }

    Ok(HealthResponse {
        status: "healthy".to_string(),
        version: "1.0.0-chatchi".to_string(),
        uptime_seconds: start_time.elapsed().as_secs(),
    })
}

pub fn handle_config(
    settings: &DeltaChatSettings,
    altcha_engine: &AltchaEngine,
    domain: String,
    endpoints: EndpointsConfig,
    password_hash_algorithm: &str,
) -> Result<ConfigDiscoveryResponse, DeltaChatError> {
    if !settings.enabled {
        return Err(DeltaChatError::DeltaChatDisabled);
    }

    let challenge = if settings.altcha_required {
        Some(altcha_engine.create_challenge().challenge)
    } else {
        None
    };

    let platform_name = PlatformNameConfig {
        en: if settings.platform_name_en.trim().is_empty() {
            "MailiaM".into()
        } else {
            settings.platform_name_en.clone()
        },
        fa: if settings.platform_name_fa.trim().is_empty() {
            "میلیم".into()
        } else {
            settings.platform_name_fa.clone()
        },
    };

    let mut download_links = Vec::with_capacity(settings.download_links.len());
    download_links.extend(
        settings
            .download_links
            .iter()
            .filter(|d| !d.link.trim().is_empty())
            .cloned(),
    );

    let mut admin_contacts = Vec::with_capacity(settings.admin_contacts.len());
    admin_contacts.extend(
        settings
            .admin_contacts
            .iter()
            .filter(|c| !c.link.trim().is_empty())
            .cloned(),
    );

    let mut donation_links = Vec::with_capacity(settings.donation_links.len());
    donation_links.extend(
        settings
            .donation_links
            .iter()
            .filter(|d| !d.link.trim().is_empty())
            .cloned(),
    );

    Ok(ConfigDiscoveryResponse {
        domain,
        registration_open: settings.registration_open,
        instant_accounts_enabled: settings.instant_accounts_enabled,
        custom_accounts_enabled: settings.custom_accounts_enabled,
        endpoints: ConfigDiscoveryEndpoints {
            imap: ConfigDiscoveryMailEndpoint {
                host: endpoints.imap.host,
                port: endpoints.imap.port,
                security: endpoints.imap.security.as_str().to_string(),
            },
            smtp: ConfigDiscoveryMailEndpoint {
                host: endpoints.smtp.host,
                port: endpoints.smtp.port,
                security: endpoints.smtp.security.as_str().to_string(),
            },
        },
        altcha: ConfigDiscoveryAltcha {
            required: settings.altcha_required,
            max_number: settings.altcha_max_number,
            challenge,
        },
        password_hash_algorithm: password_hash_algorithm.to_string(),
        certificate_checks: settings.certificate_checks.as_str().to_string(),
        instant_prefix_enabled: settings.instant_prefix_enabled,
        instant_prefix: settings.instant_prefix.clone(),
        custom_prefix_enabled: settings.custom_prefix_enabled,
        custom_prefix: settings.custom_prefix.clone(),
        platform_name,
        platform_icon: settings.platform_icon.clone(),
        platform_image_url: settings.platform_image_url.clone(),
        admin_contacts,
        donation_links,
        download_links,
    })
}

pub fn handle_altcha_challenge(
    settings: &DeltaChatSettings,
    altcha_engine: &AltchaEngine,
) -> Result<AltchaChallenge, DeltaChatError> {
    if !settings.enabled {
        return Err(DeltaChatError::DeltaChatDisabled);
    }

    Ok(altcha_engine.create_challenge())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{
        CertificateChecks, EndpointSecurity, MailEndpointConfig, endpoints_from_settings,
    };

    fn test_endpoints() -> EndpointsConfig {
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

    #[test]
    fn test_health_handler() {
        let settings = DeltaChatSettings::default();
        let start = Instant::now();
        let health = handle_health(&settings, start).unwrap();
        assert_eq!(health.status, "healthy");
        assert_eq!(health.version, "1.0.0-chatchi");

        let mut disabled = settings.clone();
        disabled.enabled = false;
        assert_eq!(
            handle_health(&disabled, start),
            Err(DeltaChatError::DeltaChatDisabled)
        );
    }

    #[test]
    fn test_config_handler() {
        let settings = DeltaChatSettings::default();
        let altcha = AltchaEngine::new(b"secret".to_vec(), 100_000);
        let config = handle_config(
            &settings,
            &altcha,
            "localhost".into(),
            test_endpoints(),
            "argon2id",
        )
        .unwrap();
        assert_eq!(config.domain, "localhost");
        assert_eq!(config.endpoints.imap.port, 993);
        assert_eq!(config.endpoints.smtp.port, 465);
        assert!(!config.altcha.required);
        assert!(config.altcha.challenge.is_none());
    }

    #[test]
    fn config_includes_hash_algorithm_and_ic() {
        let settings = DeltaChatSettings {
            imap: MailEndpointConfig {
                host: "imap.example.org".into(),
                port: 993,
                security: EndpointSecurity::Ssl,
            },
            smtp: MailEndpointConfig {
                host: "smtp.example.org".into(),
                port: 465,
                security: EndpointSecurity::Ssl,
            },
            certificate_checks: CertificateChecks::Strict,
            ..Default::default()
        };
        let engine = AltchaEngine::new(b"secret".to_vec(), 1000);
        let resp = handle_config(
            &settings,
            &engine,
            "example.org".into(),
            endpoints_from_settings(&settings).unwrap(),
            "argon2id",
        )
        .unwrap();
        assert_eq!(resp.password_hash_algorithm, "argon2id");
        assert_eq!(resp.certificate_checks, "1");
        assert_eq!(resp.endpoints.imap.host, "imap.example.org");
    }

    #[test]
    fn config_includes_prefix_settings() {
        let settings = DeltaChatSettings {
            instant_prefix_enabled: true,
            instant_prefix: "chat_".into(),
            custom_prefix_enabled: true,
            custom_prefix: "user_".into(),
            ..Default::default()
        };

        let engine = AltchaEngine::new(b"secret".to_vec(), 1000);
        let resp = handle_config(
            &settings,
            &engine,
            "example.org".into(),
            endpoints_from_settings(&settings).unwrap(),
            "argon2id",
        )
        .unwrap();

        assert!(resp.instant_prefix_enabled);
        assert_eq!(resp.instant_prefix, "chat_");
        assert!(resp.custom_prefix_enabled);
        assert_eq!(resp.custom_prefix, "user_");
    }

    #[test]
    fn test_altcha_challenge_handler() {
        let settings = DeltaChatSettings::default();
        let altcha = AltchaEngine::new(b"secret".to_vec(), 100_000);
        let challenge = handle_altcha_challenge(&settings, &altcha).unwrap();
        assert_eq!(challenge.algorithm, "SHA-256");
        assert_eq!(challenge.max_number, 100_000);
    }

    #[test]
    fn test_config_handler_relay_page_data() {
        let settings = DeltaChatSettings {
            platform_name_en: "MailiaM".into(),
            platform_name_fa: "میلیم".into(),
            platform_icon: "/logo.svg".into(),
            platform_image_url: "https://example.org/banner.png".into(),
            admin_contacts: vec![
                crate::config::LinkItem {
                    id: "tg".into(),
                    title: "Telegram".into(),
                    title_fa: "تلگرام".into(),
                    link: "https://t.me/example".into(),
                    icon: "telegram".into(),
                    image_url: "".into(),
                },
                crate::config::LinkItem {
                    id: "empty_contact".into(),
                    title: "Empty".into(),
                    title_fa: "".into(),
                    link: "   ".into(), // Empty link must be filtered out!
                    icon: "".into(),
                    image_url: "".into(),
                },
            ],
            donation_links: vec![
                crate::config::LinkItem {
                    id: "btc".into(),
                    title: "Bitcoin".into(),
                    title_fa: "بیت‌کوین".into(),
                    link: "bitcoin:bc1q...".into(),
                    icon: "bitcoin".into(),
                    image_url: "".into(),
                },
                crate::config::LinkItem {
                    id: "empty_donation".into(),
                    title: "Empty".into(),
                    title_fa: "".into(),
                    link: "".into(), // Empty link must be filtered out!
                    icon: "".into(),
                    image_url: "".into(),
                },
            ],
            download_links: vec![
                crate::config::DownloadLinkItem {
                    id: "gp".into(),
                    title: "Google Play".into(),
                    title_fa: "گوگل پلی".into(),
                    link: "https://play.google.com".into(),
                    is_direct: false,
                    icon: "google-play".into(),
                    image_url: "".into(),
                },
                crate::config::DownloadLinkItem {
                    id: "direct_empty".into(),
                    title: "Direct APK".into(),
                    title_fa: "".into(),
                    link: "   ".into(), // Empty link must be filtered out!
                    is_direct: true,
                    icon: "download".into(),
                    image_url: "".into(),
                },
            ],
            ..Default::default()
        };

        let altcha = AltchaEngine::new(b"secret".to_vec(), 100_000);
        let endpoints = test_endpoints();
        let resp = handle_config(
            &settings,
            &altcha,
            "localhost".into(),
            endpoints,
            "argon2id",
        )
        .unwrap();

        assert_eq!(resp.platform_name.en, "MailiaM");
        assert_eq!(resp.platform_name.fa, "میلیم");
        assert_eq!(resp.platform_icon, "/logo.svg");
        assert_eq!(resp.platform_image_url, "https://example.org/banner.png");
        assert_eq!(resp.admin_contacts.len(), 1);
        assert_eq!(resp.admin_contacts[0].id, "tg");
        assert_eq!(resp.donation_links.len(), 1);
        assert_eq!(resp.donation_links[0].id, "btc");
        // Empty link filtered:
        assert_eq!(resp.download_links.len(), 1);
        assert_eq!(resp.download_links[0].id, "gp");

        // Verify fallback when names are whitespace or empty
        let empty_names = DeltaChatSettings {
            platform_name_en: "   ".into(),
            platform_name_fa: "".into(),
            ..Default::default()
        };
        let resp_fallback = handle_config(
            &empty_names,
            &altcha,
            "localhost".into(),
            test_endpoints(),
            "argon2id",
        )
        .unwrap();
        assert_eq!(resp_fallback.platform_name.en, "MailiaM");
        assert_eq!(resp_fallback.platform_name.fa, "میلیم");
    }
}
