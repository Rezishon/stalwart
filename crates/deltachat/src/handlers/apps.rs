/*
 * SPDX-FileCopyrightText: 2026 Stalwart Labs LLC <hello@stalw.art>
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
 */

use crate::catalog::CatalogStore;
use crate::config::DeltaChatSettings;
use crate::error::DeltaChatError;
use crate::models::AppsCatalogResponse;

pub fn handle_get_apps(settings: &DeltaChatSettings) -> Result<AppsCatalogResponse, DeltaChatError> {
    if !settings.enabled {
        return Err(DeltaChatError::DeltaChatDisabled);
    }

    Ok(CatalogStore::get_catalog())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_handle_get_apps() {
        let settings = DeltaChatSettings::default();
        let catalog = handle_get_apps(&settings).unwrap();
        assert_eq!(catalog.apps.len(), 2);

        let mut disabled = settings.clone();
        disabled.enabled = false;
        assert_eq!(
            handle_get_apps(&disabled),
            Err(DeltaChatError::DeltaChatDisabled)
        );
    }
}
