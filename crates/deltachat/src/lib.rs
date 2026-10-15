/*
 * SPDX-FileCopyrightText: 2026 Stalwart Labs LLC <hello@stalw.art>
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
 */

pub mod altcha;
pub mod assets;
pub mod catalog;
pub mod config;
pub mod dclogin;
pub mod error;
pub mod handlers;
pub mod models;
pub mod password_hash;
pub mod router;

pub use router::{DeltaChatRouter, dispatch_web_asset, dispatch_xdc_asset};
