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

const RESERVED_NAMES: &[&str] = &[
    "admin",
    "administrator",
    "root",
    "postmaster",
    "hostmaster",
    "webmaster",
    "abuse",
    "mailer-daemon",
    "nobody",
    "support",
    "security",
    "noc",
    "dmarc",
    "dkim",
    "sales",
    "info",
    "daemon",
    "help",
];

pub fn validate_username(username: &str) -> Result<(), DeltaChatError> {
    let u = username.trim().to_ascii_lowercase();
    if u.len() < 3 || u.len() > 32 {
        return Err(DeltaChatError::InvalidUsername(
            "Username must be between 3 and 32 characters".to_string(),
        ));
    }

    if u.starts_with("dc_") {
        return Err(DeltaChatError::InvalidUsername(
            "Username prefix 'dc_' is reserved for instant accounts".to_string(),
        ));
    }

    if RESERVED_NAMES.contains(&u.as_str()) {
        return Err(DeltaChatError::InvalidUsername(
            "Username is reserved".to_string(),
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

    Ok(())
}

pub fn validate_instant_username(username: &str) -> Result<(), DeltaChatError> {
    let u = username.trim().to_ascii_lowercase();
    let ok = u.len() == 15
        && u.starts_with("dc_")
        && u.as_bytes()[3..]
            .iter()
            .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'));
    if ok {
        Ok(())
    } else {
        Err(DeltaChatError::InvalidUsername(
            "Instant username must match dc_ + 12 hex chars".into(),
        ))
    }
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
    domain: &str,
) -> Result<(), DeltaChatError> {
    let mut endpoints = endpoints_from_settings(settings)?;
    fill_empty_endpoint_hosts(&mut endpoints, domain);
    if endpoints.imap.host.is_empty() || endpoints.smtp.host.is_empty() {
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

    validate_instant_username(&req.username)?;

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
    require_advertised_hosts(settings, domain_name)?;
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

    validate_username(&req.username)?;

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
    require_advertised_hosts(settings, domain_name)?;

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
        assert!(validate_username("alice").is_ok());
        assert!(validate_username("bob_123").is_ok());
        assert!(validate_username("carol.smith").is_ok());

        assert!(validate_username("al").is_err()); // Too short
        assert!(validate_username("a".repeat(33).as_str()).is_err()); // Too long
        assert!(validate_username("admin").is_err()); // Reserved
        assert!(validate_username("root").is_err()); // Reserved
        assert!(validate_username(".leading").is_err()); // Leading dot
        assert!(validate_username("trailing.").is_err()); // Trailing dot
        assert!(validate_username("consecutive..dots").is_err()); // Consecutive dots
        assert!(validate_username("invalid@char").is_err()); // Invalid character
    }

    #[test]
    fn instant_username_must_be_dc_hex12() {
        assert!(validate_instant_username("dc_0123456789ab").is_ok());
        assert!(validate_instant_username("alice").is_err());
        assert!(validate_instant_username("dc_ZZ").is_err());
    }

    #[test]
    fn plaintext_password_field_is_rejected_by_model() {
        let json = r#"{"username":"dc_0123456789ab","password":"secret","password_hash":"$argon2id$x"}"#;
        let req: InstantAccountRequest = serde_json::from_str(json).unwrap();
        assert!(req.password.is_some());
    }

    #[test]
    fn custom_still_rejects_dc_prefix() {
        assert!(validate_username("dc_alice").is_err());
    }

    #[test]
    fn empty_hosts_ok_when_primary_domain_present() {
        let settings = DeltaChatSettings::default();
        assert!(require_advertised_hosts(&settings, "example.org").is_ok());
    }

    #[test]
    fn empty_hosts_fail_without_domain() {
        let settings = DeltaChatSettings::default();
        assert_eq!(
            require_advertised_hosts(&settings, ""),
            Err(DeltaChatError::EndpointsNotConfigured)
        );
    }
}
