/*
 * SPDX-FileCopyrightText: 2026 Stalwart Labs LLC <hello@stalw.art>
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
 */

use crate::error::DeltaChatError;
use base64::Engine;
use hmac::{Hmac, KeyInit, Mac};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use utils::cache::CacheWithTtl;

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AltchaChallenge {
    pub algorithm: String,
    pub challenge: String,
    pub salt: String,
    pub signature: String,
    #[serde(alias = "maxnumber")]
    pub max_number: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AltchaPayload {
    pub algorithm: String,
    pub challenge: String,
    pub number: u64,
    pub salt: String,
    pub signature: String,
}

pub struct AltchaEngine {
    secret_key: Vec<u8>,
    max_number: u64,
    replay_cache: Arc<CacheWithTtl<Box<str>, bool>>,
}

impl AltchaEngine {
    pub fn new(secret_key: Vec<u8>, max_number: u64) -> Self {
        Self::with_cache(
            secret_key,
            max_number,
            Arc::new(CacheWithTtl::new_estimated(10_000, 4 * 1024 * 1024)),
        )
    }

    pub fn with_cache(
        secret_key: Vec<u8>,
        max_number: u64,
        replay_cache: Arc<CacheWithTtl<Box<str>, bool>>,
    ) -> Self {
        Self {
            secret_key,
            max_number,
            replay_cache,
        }
    }

    pub fn compute_signature(&self, salt: &str, challenge: &str) -> Vec<u8> {
        let mut mac = HmacSha256::new_from_slice(&self.secret_key)
            .expect("HMAC can accept keys of any size");
        mac.update(salt.as_bytes());
        mac.update(b":");
        mac.update(challenge.as_bytes());
        mac.finalize().into_bytes().to_vec()
    }

    pub fn create_challenge(&self) -> AltchaChallenge {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let random_part: u64 = store::rand::random();
        let salt = format!("{now}:{random_part:016x}");
        let random_num: u64 = store::rand::random();
        let number = if self.max_number > 0 {
            random_num % (self.max_number + 1)
        } else {
            0
        };
        let challenge = Self::compute_hash(&salt, number);
        let signature = hex::encode(self.compute_signature(&salt, &challenge));

        AltchaChallenge {
            algorithm: "SHA-256".to_string(),
            challenge,
            salt,
            signature,
            max_number: self.max_number,
        }
    }

    pub fn compute_hash(salt: &str, number: u64) -> String {
        let mut hasher = Sha256::new();
        hasher.update(salt.as_bytes());
        hasher.update(number.to_string().as_bytes());
        hex::encode(hasher.finalize())
    }

    pub fn parse_payload(raw: &str) -> Result<AltchaPayload, DeltaChatError> {
        let trimmed = raw.trim();
        // Try direct JSON first
        if let Ok(payload) = serde_json::from_str::<AltchaPayload>(trimmed) {
            return Ok(payload);
        }
        // Try base64 standard decoding
        if let Ok(decoded) = base64::prelude::BASE64_STANDARD.decode(trimmed)
            && let Ok(payload) = serde_json::from_slice::<AltchaPayload>(&decoded)
        {
            return Ok(payload);
        }
        // Try base64 URL safe decoding
        if let Ok(decoded) = base64::prelude::BASE64_URL_SAFE.decode(trimmed)
            && let Ok(payload) = serde_json::from_slice::<AltchaPayload>(&decoded)
        {
            return Ok(payload);
        }
        // Try base64 URL safe unpadded
        if let Ok(decoded) = base64::prelude::BASE64_URL_SAFE_NO_PAD.decode(trimmed)
            && let Ok(payload) = serde_json::from_slice::<AltchaPayload>(&decoded)
        {
            return Ok(payload);
        }
        Err(DeltaChatError::AltchaInvalid)
    }

    pub fn verify_payload(&self, payload: &AltchaPayload) -> Result<(), DeltaChatError> {
        if self.secret_key.is_empty() {
            return Err(DeltaChatError::Internal("Altcha HMAC secret unconfigured".to_string()));
        }
        if payload.algorithm != "SHA-256" {
            return Err(DeltaChatError::AltchaInvalid);
        }
        if payload.number > self.max_number {
            return Err(DeltaChatError::AltchaInvalid);
        }

        // 1. Timestamp validation (120s window)
        let parts: Vec<&str> = payload.salt.split(':').collect();
        if parts.len() < 2 {
            return Err(DeltaChatError::AltchaInvalid);
        }
        let ts: u64 = parts[0]
            .parse()
            .map_err(|_| DeltaChatError::AltchaInvalid)?;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        if now.abs_diff(ts) > 120 {
            return Err(DeltaChatError::AltchaInvalid);
        }

        // 2. Constant-time Signature Verification
        let sig_bytes = hex::decode(&payload.signature)
            .map_err(|_| DeltaChatError::AltchaInvalid)?;
        let mut mac = HmacSha256::new_from_slice(&self.secret_key)
            .map_err(|_| DeltaChatError::AltchaInvalid)?;
        mac.update(payload.salt.as_bytes());
        mac.update(b":");
        mac.update(payload.challenge.as_bytes());
        mac.verify_slice(&sig_bytes)
            .map_err(|_| DeltaChatError::AltchaInvalid)?;

        // 3. PoW hash check
        let expected_hash = Self::compute_hash(&payload.salt, payload.number);
        if expected_hash != payload.challenge {
            return Err(DeltaChatError::AltchaInvalid);
        }

        // 4. Replay check with 120s TTL
        let key = payload.challenge.clone().into_boxed_str();
        if self.replay_cache.get(&key).is_some() {
            return Err(DeltaChatError::AltchaReplay);
        }
        self.replay_cache
            .insert(key, true, Duration::from_secs(120));

        Ok(())
    }

    pub fn verify_raw(&self, raw: &str) -> Result<(), DeltaChatError> {
        let payload = Self::parse_payload(raw)?;
        self.verify_payload(&payload)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_altcha_pow_generation_and_verification() {
        let key = b"test-secret-key-1234567890123456".to_vec();
        let engine = AltchaEngine::new(key, 5_000);

        let challenge = engine.create_challenge();
        assert_eq!(challenge.algorithm, "SHA-256");

        // Solve puzzle
        let mut solved_number = None;
        for n in 0..=5_000 {
            if AltchaEngine::compute_hash(&challenge.salt, n) == challenge.challenge {
                solved_number = Some(n);
                break;
            }
        }
        let number = solved_number.expect("puzzle solution exists within max_number");

        let payload = AltchaPayload {
            algorithm: challenge.algorithm,
            challenge: challenge.challenge,
            number,
            salt: challenge.salt,
            signature: challenge.signature,
        };

        // First verification succeeds
        assert!(engine.verify_payload(&payload).is_ok());

        // Replay verification fails
        assert_eq!(
            engine.verify_payload(&payload),
            Err(DeltaChatError::AltchaReplay)
        );
    }

    #[test]
    fn test_altcha_invalid_signature_and_solution() {
        let key = b"test-secret-key-1234567890123456".to_vec();
        let engine = AltchaEngine::new(key, 1_000);
        let challenge = engine.create_challenge();

        // Wrong number
        let payload_bad_num = AltchaPayload {
            algorithm: challenge.algorithm.clone(),
            challenge: challenge.challenge.clone(),
            number: 999_999,
            salt: challenge.salt.clone(),
            signature: challenge.signature.clone(),
        };
        assert!(engine.verify_payload(&payload_bad_num).is_err());

        // Forged signature
        let payload_bad_sig = AltchaPayload {
            algorithm: challenge.algorithm,
            challenge: challenge.challenge,
            number: 0,
            salt: challenge.salt,
            signature: "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff".into(),
        };
        assert_eq!(
            engine.verify_payload(&payload_bad_sig),
            Err(DeltaChatError::AltchaInvalid)
        );
    }

    #[test]
    fn test_altcha_parse_payload_base64_and_json() {
        let payload = AltchaPayload {
            algorithm: "SHA-256".into(),
            challenge: "abcd".into(),
            number: 42,
            salt: "123:456".into(),
            signature: "deadbeef".into(),
        };
        let json_str = serde_json::to_string(&payload).unwrap();
        let parsed_json = AltchaEngine::parse_payload(&json_str).unwrap();
        assert_eq!(parsed_json, payload);

        let b64 = base64::prelude::BASE64_STANDARD.encode(&json_str);
        let parsed_b64 = AltchaEngine::parse_payload(&b64).unwrap();
        assert_eq!(parsed_b64, payload);
    }
}
