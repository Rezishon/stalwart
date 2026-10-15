/*
 * SPDX-FileCopyrightText: 2026 Stalwart Labs LLC <hello@stalw.art>
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
 */

use registry::schema::enums::PasswordHashAlgorithm;

pub fn password_hash_matches(algorithm: PasswordHashAlgorithm, hash: &str) -> bool {
    let prefix = match algorithm {
        PasswordHashAlgorithm::Argon2id => "$argon2id$",
        PasswordHashAlgorithm::Bcrypt => "$2",
        PasswordHashAlgorithm::Scrypt => "$scrypt$",
        PasswordHashAlgorithm::Pbkdf2 => "$pbkdf2",
    };
    hash.starts_with(prefix)
}

#[cfg(test)]
mod tests {
    use super::*;
    use registry::schema::enums::PasswordHashAlgorithm;

    #[test]
    fn accepts_matching_prefix() {
        assert!(password_hash_matches(
            PasswordHashAlgorithm::Argon2id,
            "$argon2id$v=19$m=16,t=2,p=1$c2FsdHNhbHQ$dummy"
        ));
        assert!(password_hash_matches(
            PasswordHashAlgorithm::Bcrypt,
            "$2b$10$abcdefghijklmnopqrstuu12345678901234567890123"
        ));
        assert!(password_hash_matches(
            PasswordHashAlgorithm::Scrypt,
            "$scrypt$ln=15,r=8,p=1$c2FsdA$hash"
        ));
        assert!(password_hash_matches(
            PasswordHashAlgorithm::Pbkdf2,
            "$pbkdf2-sha256$29000$c2FsdA$hash"
        ));
    }

    #[test]
    fn rejects_wrong_algorithm_and_garbage() {
        assert!(!password_hash_matches(
            PasswordHashAlgorithm::Argon2id,
            "$2b$10$notargon"
        ));
        assert!(!password_hash_matches(
            PasswordHashAlgorithm::Argon2id,
            "plaintext"
        ));
        assert!(!password_hash_matches(
            PasswordHashAlgorithm::Argon2id,
            ""
        ));
        assert!(!password_hash_matches(
            PasswordHashAlgorithm::Argon2id,
            "$argon2i$v=19$m=16,t=2,p=1$xx$yy"
        ));
    }
}
