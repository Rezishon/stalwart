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
    ConfigDiscoveryResponse, HealthResponse,
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
) -> Result<ConfigDiscoveryResponse, DeltaChatError> {
    if !settings.enabled {
        return Err(DeltaChatError::DeltaChatDisabled);
    }

    let challenge = if settings.altcha_required {
        Some(altcha_engine.create_challenge().challenge)
    } else {
        None
    };

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
    use crate::config::{EndpointSecurity, MailEndpointConfig};

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
        )
        .unwrap();
        assert_eq!(config.domain, "localhost");
        assert_eq!(config.endpoints.imap.port, 993);
        assert_eq!(config.endpoints.smtp.port, 465);
        assert!(!config.altcha.required);
        assert!(config.altcha.challenge.is_none());
    }

    #[test]
    fn test_altcha_challenge_handler() {
        let settings = DeltaChatSettings::default();
        let altcha = AltchaEngine::new(b"secret".to_vec(), 100_000);
        let challenge = handle_altcha_challenge(&settings, &altcha).unwrap();
        assert_eq!(challenge.algorithm, "SHA-256");
        assert_eq!(challenge.max_number, 100_000);
    }
}
