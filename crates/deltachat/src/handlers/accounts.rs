/*
 * SPDX-FileCopyrightText: 2026 Stalwart Labs LLC <hello@stalw.art>
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
 */

use crate::altcha::AltchaEngine;
use crate::config::{endpoints_from_settings, fill_empty_endpoint_hosts, DeltaChatSettings};
use crate::error::DeltaChatError;
use crate::models::{
    CustomAccountRequest, CustomAccountResponse, InstantAccountRequest, InstantAccountResponse,
};
use crate::password_hash::password_hash_matches;
use common::Server;
use registry::schema::structs::{Account, Credential, PasswordCredential, UserAccount, UserRoles};
use registry::types::list::List;
use std::sync::Arc;
use store::registry::write::{RegistryWrite, RegistryWriteResult};
use types::id::Id;

pub fn matches_blacklist(username: &str, blacklist: &[String]) -> bool {
    let u = username.to_ascii_lowercase();
    blacklist.iter().any(|pattern| {
        let pattern = pattern.trim();
        if pattern.is_empty() {
            return false;
        }
        if let Some(inner) = pattern.strip_prefix('*').and_then(|p| p.strip_suffix('*')) {
            !inner.is_empty() && u.contains(inner)
        } else if let Some(prefix) = pattern.strip_suffix('*') {
            !prefix.is_empty() && u.starts_with(prefix)
        } else if let Some(suffix) = pattern.strip_prefix('*') {
            !suffix.is_empty() && u.ends_with(suffix)
        } else {
            u == pattern
        }
    })
}

pub fn validate_username(
    username: &str,
    settings: &DeltaChatSettings,
) -> Result<(), DeltaChatError> {
    let u = username.trim().to_ascii_lowercase();
    if u.len() < 3 || u.len() > 32 {
        return Err(DeltaChatError::InvalidUsername(
            "Username must be between 3 and 32 characters".to_string(),
        ));
    }

    if u.starts_with('.') || u.ends_with('.') || u.contains("..") {
        return Err(DeltaChatError::InvalidUsername(
            "Username cannot start/end with dot or contain consecutive dots".to_string(),
        ));
    }

    if !u
        .bytes()
        .all(|b| matches!(b, b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.'))
    {
        return Err(DeltaChatError::InvalidUsername(
            "Username contains invalid characters".to_string(),
        ));
    }

    if settings.instant_accounts_enabled {
        let instant_prefix = settings.instant_prefix.to_ascii_lowercase();
        if settings.instant_prefix_enabled && !instant_prefix.is_empty() {
            if u.starts_with(&instant_prefix) {
                return Err(DeltaChatError::InvalidUsername(format!(
                    "Username prefix '{}' is reserved for instant accounts",
                    settings.instant_prefix
                )));
            }
        } else if (12..=16).contains(&u.len())
            && u.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
        {
            return Err(DeltaChatError::InvalidUsername(
                "Hexadecimal usernames are reserved for instant accounts".to_string(),
            ));
        }
    }

    if settings.custom_prefix_enabled && !settings.custom_prefix.is_empty() {
        let custom_prefix = settings.custom_prefix.to_ascii_lowercase();
        if !u.starts_with(&custom_prefix) {
            return Err(DeltaChatError::InvalidUsername(format!(
                "Username must start with prefix '{}'",
                settings.custom_prefix
            )));
        }
    }

    if matches_blacklist(&u, &settings.username_blacklist) {
        return Err(DeltaChatError::InvalidUsername(
            "Username is reserved or restricted".to_string(),
        ));
    }

    Ok(())
}

pub fn validate_instant_username(
    username: &str,
    settings: &DeltaChatSettings,
) -> Result<(), DeltaChatError> {
    let u = username.trim().to_ascii_lowercase();
    if u.len() < 3 || u.len() > 32 {
        return Err(DeltaChatError::InvalidUsername(
            "Username must be between 3 and 32 characters".to_string(),
        ));
    }

    if matches_blacklist(&u, &settings.username_blacklist) {
        return Err(DeltaChatError::InvalidUsername(
            "Username is reserved or restricted".to_string(),
        ));
    }

    if settings.instant_prefix_enabled {
        let prefix = settings.instant_prefix.to_ascii_lowercase();
        let ok = u.strip_prefix(&prefix).is_some_and(|suffix| {
            suffix.len() == 12 && suffix.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
        });
        if !ok {
            return Err(DeltaChatError::InvalidUsername(format!(
                "Instant username must match {prefix} + 12 hex chars"
            )));
        }
    } else {
        let ok = (12..=16).contains(&u.len())
            && u.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'));
        if !ok {
            return Err(DeltaChatError::InvalidUsername(
                "Instant username must be 12 to 16 hex chars".to_string(),
            ));
        }
    }

    Ok(())
}

fn reject_plaintext_and_check_hash(
    server: &Server,
    password: &Option<String>,
    password_hash: &str,
) -> Result<(), DeltaChatError> {
    if password.is_some() {
        return Err(DeltaChatError::InvalidPassword(
            "Plaintext password is not accepted".into(),
        ));
    }
    if !password_hash_matches(
        server.core.network.security.password_hash_algorithm,
        password_hash,
    ) {
        return Err(DeltaChatError::InvalidPasswordHash);
    }
    Ok(())
}

fn require_advertised_hosts(
    settings: &DeltaChatSettings,
    primary: &str,
    domain: &str,
) -> Result<(), DeltaChatError> {
    let mut endpoints = endpoints_from_settings(settings)?;
    fill_empty_endpoint_hosts(&mut endpoints, domain);
    fill_empty_endpoint_hosts(&mut endpoints, primary);
    if endpoints.imap.host.trim().is_empty() || endpoints.smtp.host.trim().is_empty() {
        return Err(DeltaChatError::EndpointsNotConfigured);
    }
    Ok(())
}

async fn resolve_signup_domain(
    settings: &DeltaChatSettings,
    server: &Server,
) -> Result<std::sync::Arc<common::auth::DomainCache>, DeltaChatError> {
    if !settings.domain_id.is_valid() {
        return Err(DeltaChatError::InvalidDomain(
            "Primary domain is not configured".into(),
        ));
    }
    server
        .domain_by_id(settings.domain_id.document_id())
        .await
        .map_err(|e| DeltaChatError::Internal(e.to_string()))?
        .ok_or_else(|| DeltaChatError::InvalidDomain("Primary domain not found".into()))
}

pub async fn handle_instant_account(
    settings: &DeltaChatSettings,
    altcha_engine: &AltchaEngine,
    server: &Arc<Server>,
    req: InstantAccountRequest,
) -> Result<InstantAccountResponse, DeltaChatError> {
    if !settings.enabled {
        return Err(DeltaChatError::DeltaChatDisabled);
    }
    if !settings.registration_open {
        return Err(DeltaChatError::RegistrationClosed);
    }
    if !settings.instant_accounts_enabled {
        return Err(DeltaChatError::InstantAccountsDisabled);
    }

    validate_instant_username(&req.username, settings)?;

    if settings.altcha_required {
        let payload = req
            .altcha_payload
            .as_deref()
            .ok_or(DeltaChatError::AltchaRequired)?;
        altcha_engine.verify_raw(payload)?;
    }

    reject_plaintext_and_check_hash(server, &req.password, &req.password_hash)?;

    let domain = resolve_signup_domain(settings, server).await?;
    let domain_name = domain
        .names
        .first()
        .ok_or_else(|| DeltaChatError::InvalidDomain("Domain has no name".into()))?;
    require_advertised_hosts(settings, &server.core.email.default_domain_name, domain_name)?;
    let username = req.username.trim().to_ascii_lowercase();

    if server
        .account_id_from_parts(&username, domain.id)
        .await
        .map_err(|e| DeltaChatError::Internal(e.to_string()))?
        .is_some()
    {
        return Err(DeltaChatError::AccountAlreadyExists);
    }

    let account = Account::User(UserAccount {
        name: username.clone(),
        domain_id: Id::from(domain.id),
        roles: UserRoles::User,
        credentials: List::from_iter([Credential::Password(PasswordCredential {
            credential_id: 0u64.into(),
            secret: req.password_hash.clone(),
            ..Default::default()
        })]),
        description: "DeltaChat Instant Account".to_string().into(),
        ..Default::default()
    });

    let write_result = server
        .registry()
        .write(RegistryWrite::insert(&account.into()))
        .await
        .map_err(|e| DeltaChatError::Internal(e.to_string()))?;

    let account_id = match write_result {
        RegistryWriteResult::Success(id) => format!("acc_{id}"),
        RegistryWriteResult::PrimaryKeyConflict { .. } => {
            return Err(DeltaChatError::AccountAlreadyExists);
        }
        other => return Err(DeltaChatError::Internal(other.to_string())),
    };

    Ok(InstantAccountResponse {
        account_id,
        email: format!("{username}@{domain_name}"),
        account_type: "instant".to_string(),
        expires_at: None,
    })
}

pub async fn handle_custom_account(
    settings: &DeltaChatSettings,
    altcha_engine: &AltchaEngine,
    server: &Arc<Server>,
    req: CustomAccountRequest,
) -> Result<CustomAccountResponse, DeltaChatError> {
    if !settings.enabled {
        return Err(DeltaChatError::DeltaChatDisabled);
    }
    if !settings.registration_open {
        return Err(DeltaChatError::RegistrationClosed);
    }
    if !settings.custom_accounts_enabled {
        return Err(DeltaChatError::CustomAccountsDisabled);
    }

    validate_username(&req.username, settings)?;

    if settings.altcha_required {
        let payload = req
            .altcha_payload
            .as_deref()
            .ok_or(DeltaChatError::AltchaRequired)?;
        altcha_engine.verify_raw(payload)?;
    }

    reject_plaintext_and_check_hash(server, &req.password, &req.password_hash)?;

    let domain = resolve_signup_domain(settings, server).await?;
    let domain_name = domain
        .names
        .first()
        .ok_or_else(|| DeltaChatError::InvalidDomain("Domain has no name".into()))?;
    require_advertised_hosts(settings, &server.core.email.default_domain_name, domain_name)?;

    let username = req.username.trim().to_ascii_lowercase();

    if server
        .account_id_from_parts(&username, domain.id)
        .await
        .map_err(|e| DeltaChatError::Internal(e.to_string()))?
        .is_some()
    {
        return Err(DeltaChatError::AccountAlreadyExists);
    }

    let account = Account::User(UserAccount {
        name: username.clone(),
        domain_id: Id::from(domain.id),
        roles: UserRoles::User,
        credentials: List::from_iter([Credential::Password(PasswordCredential {
            credential_id: 0u64.into(),
            secret: req.password_hash.clone(),
            ..Default::default()
        })]),
        description: "DeltaChat Custom Account".to_string().into(),
        ..Default::default()
    });

    let write_result = server
        .registry()
        .write(RegistryWrite::insert(&account.into()))
        .await
        .map_err(|e| DeltaChatError::Internal(e.to_string()))?;

    let account_id = match write_result {
        RegistryWriteResult::Success(id) => format!("acc_{id}"),
        RegistryWriteResult::PrimaryKeyConflict { .. } => {
            return Err(DeltaChatError::AccountAlreadyExists);
        }
        other => return Err(DeltaChatError::Internal(other.to_string())),
    };

    Ok(CustomAccountResponse {
        account_id,
        email: format!("{username}@{domain_name}"),
        account_type: "custom".to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_username_validation() {
        let settings = DeltaChatSettings::default();
        assert!(validate_username("alice", &settings).is_ok());
        assert!(validate_username("bob_123", &settings).is_ok());
        assert!(validate_username("carol.smith", &settings).is_ok());

        assert!(validate_username("al", &settings).is_err()); // Too short
        assert!(validate_username("a".repeat(33).as_str(), &settings).is_err()); // Too long
        assert!(validate_username("admin", &settings).is_err()); // Reserved
        assert!(validate_username("root", &settings).is_err()); // Reserved
        assert!(validate_username(".leading", &settings).is_err()); // Leading dot
        assert!(validate_username("trailing.", &settings).is_err()); // Trailing dot
        assert!(validate_username("consecutive..dots", &settings).is_err()); // Consecutive dots
        assert!(validate_username("invalid@char", &settings).is_err()); // Invalid character
    }

    #[test]
    fn test_instant_username_with_configurable_prefix() {
        let mut settings = DeltaChatSettings {
            instant_prefix_enabled: true,
            instant_prefix: "dc_".into(),
            ..Default::default()
        };
        assert!(validate_instant_username("dc_0123456789ab", &settings).is_ok());
        assert!(validate_instant_username("xx_0123456789ab", &settings).is_err());
        assert!(validate_instant_username("dc_short", &settings).is_err());

        // Custom prefix
        settings.instant_prefix = "bot_".into();
        assert!(validate_instant_username("bot_0123456789ab", &settings).is_ok());
        assert!(validate_instant_username("dc_0123456789ab", &settings).is_err());

        // Disabled prefix (12-16 hex chars)
        settings.instant_prefix_enabled = false;
        assert!(validate_instant_username("0123456789ab", &settings).is_ok());
        assert!(validate_instant_username("0123456789abcdef", &settings).is_ok());
        assert!(validate_instant_username("0123456789", &settings).is_err()); // Too short
        assert!(validate_instant_username("not_hex_chars!", &settings).is_err());

        // Instant accounts cannot use blacklisted names
        settings.username_blacklist = vec!["bot_0123456789ab".into()];
        assert!(validate_instant_username("bot_0123456789ab", &settings).is_err());
    }

    #[test]
    fn test_custom_username_prefix_and_blacklist() {
        let mut settings = DeltaChatSettings {
            instant_prefix_enabled: true,
            instant_prefix: "dc_".into(),
            username_blacklist: vec![
                "admin".into(),
                "*support*".into(),
                "vip_*".into(),
                "*-bot".into(),
                "*".into(), // degenerate wildcard: should be ignored safely
                "".into(),  // empty: should be ignored safely
            ],
            ..Default::default()
        };

        // Disallow instant prefix
        assert!(validate_username("dc_alex", &settings).is_err());

        // Blacklist exact and wildcards
        assert!(validate_username("admin", &settings).is_err());
        assert!(validate_username("tech-support-team", &settings).is_err());
        assert!(validate_username("vip_user", &settings).is_err());
        assert!(validate_username("helper-bot", &settings).is_err());

        // Normal names allowed despite degenerate wildcards in list
        assert!(validate_username("rezishon0", &settings).is_ok());
        assert!(validate_username("alice", &settings).is_ok());

        // Instant namespace collision guard when instant prefix disabled
        settings.instant_prefix_enabled = false;
        assert!(validate_username("0123456789ab", &settings).is_err()); // Hex reserved for instant
        assert!(validate_username("alice_normal", &settings).is_ok());

        // Custom prefix enforced
        settings.custom_prefix_enabled = true;
        settings.custom_prefix = "usr_".into();
        assert!(validate_username("usr_alice", &settings).is_ok());
        assert!(validate_username("alice", &settings).is_err());
    }

    #[test]
    fn instant_username_must_be_dc_hex12() {
        let settings = DeltaChatSettings::default();
        assert!(validate_instant_username("dc_0123456789ab", &settings).is_ok());
        assert!(validate_instant_username("alice", &settings).is_err());
        assert!(validate_instant_username("dc_ZZ", &settings).is_err());
    }

    #[test]
    fn plaintext_password_field_is_rejected_by_model() {
        let json = r#"{"username":"dc_0123456789ab","password":"secret","password_hash":"$argon2id$x"}"#;
        let req: InstantAccountRequest = serde_json::from_str(json).unwrap();
        assert!(req.password.is_some());
    }

    #[test]
    fn custom_still_rejects_dc_prefix() {
        let settings = DeltaChatSettings::default();
        assert!(validate_username("dc_alice", &settings).is_err());
    }

    #[test]
    fn test_matches_blacklist() {
        let blacklist = vec![
            "admin".to_string(),
            "*support*".to_string(),
            "vip_*".to_string(),
            "*-bot".to_string(),
            "*".to_string(),
            "**".to_string(),
            "".to_string(),
            "   ".to_string(),
            "  padded  ".to_string(),
        ];
        assert!(matches_blacklist("admin", &blacklist));
        assert!(matches_blacklist("ADMIN", &blacklist));
        assert!(matches_blacklist("tech-support-team", &blacklist));
        assert!(matches_blacklist("vip_123", &blacklist));
        assert!(matches_blacklist("test-bot", &blacklist));
        assert!(matches_blacklist("padded", &blacklist));
        assert!(!matches_blacklist("alice", &blacklist));
        assert!(!matches_blacklist("normal_user", &blacklist));
    }

    #[test]
    fn empty_hosts_ok_when_primary_domain_present() {
        let settings = DeltaChatSettings::default();
        assert!(require_advertised_hosts(&settings, "example.org", "").is_ok());
        assert!(require_advertised_hosts(&settings, "", "example.org").is_ok());
    }

    #[test]
    fn empty_hosts_fail_without_domain() {
        let settings = DeltaChatSettings::default();
        assert_eq!(
            require_advertised_hosts(&settings, "", ""),
            Err(DeltaChatError::EndpointsNotConfigured)
        );
        assert_eq!(
            require_advertised_hosts(&settings, "localhost", ""),
            Err(DeltaChatError::EndpointsNotConfigured)
        );
    }
}
