/*
 * SPDX-FileCopyrightText: 2026 Stalwart Labs LLC <hello@stalw.art>
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
 */

use crate::altcha::AltchaEngine;
use crate::config::DeltaChatSettings;
use crate::dclogin::build_dclogin_uri;
use crate::error::DeltaChatError;
use crate::models::{
    CustomAccountRequest, CustomAccountResponse, InstantAccountRequest, InstantAccountResponse,
};
use common::Server;
use directory::core::secret::hash_secret;
use registry::schema::{
    enums::PasswordHashAlgorithm,
    structs::{Account, Credential, PasswordCredential, UserAccount, UserRoles},
};
use registry::types::list::List;
use std::sync::Arc;
use store::rand::{RngExt, distr::Alphanumeric, rng};
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

pub fn validate_password(password: &str) -> Result<(), DeltaChatError> {
    if password.len() < 8 {
        return Err(DeltaChatError::InvalidPassword(
            "Password must be at least 8 characters".to_string(),
        ));
    }
    Ok(())
}

pub fn generate_instant_credentials(domain: &str) -> (String, String) {
    let mut rng = rng();
    let hex_part: u64 = rng.random_range(0..0x1_000_000_000_000u64);
    let email = format!("dc_{hex_part:012x}@{domain}");
    let password: String = (0..24)
        .map(|_| rng.sample(Alphanumeric) as char)
        .collect();
    (email, password)
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

    // Verify Altcha if required
    if settings.altcha_required {
        let payload = req
            .altcha_payload
            .as_deref()
            .ok_or(DeltaChatError::AltchaRequired)?;
        altcha_engine.verify_raw(payload)?;
    }

    let domain = resolve_signup_domain(settings, server).await?;
    let domain_name = domain
        .names
        .first()
        .ok_or_else(|| DeltaChatError::InvalidDomain("Domain has no name".into()))?;
    let (email, password) = generate_instant_credentials(domain_name);
    let (local_part, _) = email
        .split_once('@')
        .ok_or_else(|| DeltaChatError::Internal("Invalid generated email".to_string()))?;

    let hashed_secret = hash_secret(
        PasswordHashAlgorithm::Argon2id,
        password.as_bytes().to_vec(),
    )
    .await
    .map_err(|e| DeltaChatError::Internal(e.to_string()))?;

    let account = Account::User(UserAccount {
        name: local_part.to_string(),
        domain_id: Id::from(domain.id),
        roles: UserRoles::User,
        credentials: List::from_iter([Credential::Password(PasswordCredential {
            credential_id: 0u64.into(),
            secret: hashed_secret,
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

    let dclogin_link = build_dclogin_uri(
        &email,
        &password,
        &DeltaChatSettings::advertised_endpoints(server),
    );

    Ok(InstantAccountResponse {
        account_id,
        email,
        password,
        dclogin_link,
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
    validate_password(&req.password)?;

    // Verify Altcha if required
    if settings.altcha_required {
        let payload = req
            .altcha_payload
            .as_deref()
            .ok_or(DeltaChatError::AltchaRequired)?;
        altcha_engine.verify_raw(payload)?;
    }

    let domain = resolve_signup_domain(settings, server).await?;
    let domain_name = domain
        .names
        .first()
        .ok_or_else(|| DeltaChatError::InvalidDomain("Domain has no name".into()))?;

    let username = req.username.trim().to_ascii_lowercase();

    // Check conflict
    if server
        .account_id_from_parts(&username, domain.id)
        .await
        .map_err(|e| DeltaChatError::Internal(e.to_string()))?
        .is_some()
    {
        return Err(DeltaChatError::AccountAlreadyExists);
    }

    let hashed_secret = hash_secret(
        PasswordHashAlgorithm::Argon2id,
        req.password.as_bytes().to_vec(),
    )
    .await
    .map_err(|e| DeltaChatError::Internal(e.to_string()))?;

    let account = Account::User(UserAccount {
        name: username.clone(),
        domain_id: Id::from(domain.id),
        roles: UserRoles::User,
        credentials: List::from_iter([Credential::Password(PasswordCredential {
            credential_id: 0u64.into(),
            secret: hashed_secret,
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

    let email = format!("{username}@{domain_name}");
    let dclogin_link = build_dclogin_uri(
        &email,
        &req.password,
        &DeltaChatSettings::advertised_endpoints(server),
    );

    Ok(CustomAccountResponse {
        account_id,
        email,
        dclogin_link,
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
    fn test_password_validation() {
        assert!(validate_password("12345678").is_ok());
        assert!(validate_password("short").is_err());
    }

    #[test]
    fn test_generate_instant_credentials() {
        let (email, password) = generate_instant_credentials("example.org");
        assert!(email.starts_with("dc_"));
        assert!(email.ends_with("@example.org"));
        assert_eq!(password.len(), 24);
    }
}
