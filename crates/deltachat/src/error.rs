/*
 * SPDX-FileCopyrightText: 2026 Stalwart Labs LLC <hello@stalw.art>
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
 */

use http_proto::HttpResponse;
use hyper::StatusCode;
use serde::Serialize;
use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeltaChatError {
    DeltaChatDisabled,
    RegistrationClosed,
    InstantAccountsDisabled,
    CustomAccountsDisabled,
    InvalidUsername(String),
    InvalidPassword(String),
    InvalidDomain(String),
    AccountAlreadyExists,
    AltchaRequired,
    AltchaInvalid,
    AltchaReplay,
    NotFound(&'static str),
    MethodNotAllowed,
    BadRequest(String),
    Internal(String),
}

impl fmt::Display for DeltaChatError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::DeltaChatDisabled => write!(f, "DeltaChat module is disabled"),
            Self::RegistrationClosed => write!(f, "Account registration is currently closed"),
            Self::InstantAccountsDisabled => write!(f, "Instant account creation is disabled"),
            Self::CustomAccountsDisabled => write!(f, "Custom account creation is disabled"),
            Self::InvalidUsername(msg) => write!(f, "Invalid username: {msg}"),
            Self::InvalidPassword(msg) => write!(f, "Invalid password: {msg}"),
            Self::InvalidDomain(msg) => write!(f, "Invalid domain: {msg}"),
            Self::AccountAlreadyExists => write!(f, "An account with this email already exists"),
            Self::AltchaRequired => write!(f, "Altcha proof-of-work solution is required"),
            Self::AltchaInvalid => write!(f, "Invalid Altcha challenge solution"),
            Self::AltchaReplay => write!(f, "Altcha challenge solution has already been used"),
            Self::NotFound(msg) => write!(f, "Not found: {msg}"),
            Self::MethodNotAllowed => write!(f, "Method not allowed"),
            Self::BadRequest(msg) => write!(f, "Bad request: {msg}"),
            Self::Internal(msg) => write!(f, "Internal server error: {msg}"),
        }
    }
}

impl std::error::Error for DeltaChatError {}

#[derive(Serialize)]
struct ErrorResponse<'a> {
    error: &'a str,
    message: String,
}

impl DeltaChatError {
    pub fn status(&self) -> StatusCode {
        match self {
            Self::DeltaChatDisabled | Self::NotFound(_) => StatusCode::NOT_FOUND,
            Self::MethodNotAllowed => StatusCode::METHOD_NOT_ALLOWED,
            Self::RegistrationClosed | Self::InstantAccountsDisabled | Self::CustomAccountsDisabled => {
                StatusCode::FORBIDDEN
            }
            Self::InvalidUsername(_)
            | Self::InvalidPassword(_)
            | Self::InvalidDomain(_)
            | Self::AltchaRequired
            | Self::AltchaInvalid
            | Self::AltchaReplay
            | Self::BadRequest(_) => StatusCode::BAD_REQUEST,
            Self::AccountAlreadyExists => StatusCode::CONFLICT,
            Self::Internal(_) => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }

    pub fn status_code(&self) -> u16 {
        self.status().as_u16()
    }

    pub fn error_code(&self) -> &'static str {
        match self {
            Self::DeltaChatDisabled => "deltachat_disabled",
            Self::RegistrationClosed => "registration_closed",
            Self::InstantAccountsDisabled => "instant_accounts_disabled",
            Self::CustomAccountsDisabled => "custom_accounts_disabled",
            Self::InvalidUsername(_) => "invalid_username",
            Self::InvalidPassword(_) => "invalid_password",
            Self::InvalidDomain(_) => "invalid_domain",
            Self::AccountAlreadyExists => "account_already_exists",
            Self::AltchaRequired => "altcha_required",
            Self::AltchaInvalid => "altcha_invalid",
            Self::AltchaReplay => "altcha_replay",
            Self::NotFound(_) => "not_found",
            Self::MethodNotAllowed => "method_not_allowed",
            Self::BadRequest(_) => "bad_request",
            Self::Internal(_) => "internal_error",
        }
    }

    pub fn to_json(&self) -> String {
        let payload = ErrorResponse {
            error: self.error_code(),
            message: self.to_string(),
        };
        serde_json::to_string(&payload).unwrap_or_else(|_| "{}".to_string())
    }

    pub fn to_response(&self) -> HttpResponse {
        let status = self.status();
        let body = self.to_json();
        HttpResponse::new(status)
            .with_content_type("application/json; charset=utf-8")
            .with_text_body(body)
    }
}

impl From<DeltaChatError> for HttpResponse {
    fn from(err: DeltaChatError) -> Self {
        err.to_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_error_status_codes() {
        assert_eq!(DeltaChatError::DeltaChatDisabled.status(), StatusCode::NOT_FOUND);
        assert_eq!(DeltaChatError::NotFound("not found").status(), StatusCode::NOT_FOUND);
        assert_eq!(DeltaChatError::MethodNotAllowed.status(), StatusCode::METHOD_NOT_ALLOWED);
        assert_eq!(DeltaChatError::BadRequest("bad".into()).status(), StatusCode::BAD_REQUEST);
        assert_eq!(DeltaChatError::RegistrationClosed.status(), StatusCode::FORBIDDEN);
        assert_eq!(DeltaChatError::AccountAlreadyExists.status(), StatusCode::CONFLICT);
        assert_eq!(DeltaChatError::AltchaInvalid.status(), StatusCode::BAD_REQUEST);
        assert_eq!(DeltaChatError::Internal("db fail".into()).status(), StatusCode::INTERNAL_SERVER_ERROR);

        assert_eq!(DeltaChatError::DeltaChatDisabled.status_code(), 404);
        assert_eq!(DeltaChatError::RegistrationClosed.status_code(), 403);
    }

    #[test]
    fn test_error_response_payload() {
        let err = DeltaChatError::InvalidUsername("bad!name".into());
        let resp = err.to_response();
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    }
}
