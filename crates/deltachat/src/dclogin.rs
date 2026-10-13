/*
 * SPDX-FileCopyrightText: 2026 Stalwart Labs LLC <hello@stalw.art>
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
 */

use crate::config::EndpointsConfig;

pub fn build_dclogin_uri(email: &str, password: &str, endpoints: &EndpointsConfig) -> String {
    let query = form_urlencoded::Serializer::new(String::new())
        .append_pair("p", password)
        .append_pair("v", "1")
        .append_pair("ih", &endpoints.imap.host)
        .append_pair("ip", &endpoints.imap.port.to_string())
        .append_pair("is", endpoints.imap.security.as_str())
        .append_pair("sh", &endpoints.smtp.host)
        .append_pair("sp", &endpoints.smtp.port.to_string())
        .append_pair("ss", endpoints.smtp.security.as_str())
        .append_pair("ic", "3")
        .finish();

    format!("dclogin:{email}/?{query}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{EndpointSecurity, MailEndpointConfig};

    #[test]
    fn test_build_dclogin_uri() {
        let endpoints = EndpointsConfig {
            imap: MailEndpointConfig {
                host: "mail.example.org".into(),
                port: 993,
                security: EndpointSecurity::Ssl,
            },
            smtp: MailEndpointConfig {
                host: "mail.example.org".into(),
                port: 465,
                security: EndpointSecurity::Ssl,
            },
        };

        let uri = build_dclogin_uri("user@example.org", "pass123!", &endpoints);
        assert!(uri.starts_with("dclogin:user@example.org/?"));
        assert!(uri.contains("p=pass123%21"));
        assert!(uri.contains("ih=mail.example.org"));
        assert!(uri.contains("ip=993"));
        assert!(uri.contains("is=ssl"));
        assert!(uri.contains("sh=mail.example.org"));
        assert!(uri.contains("sp=465"));
        assert!(uri.contains("ss=ssl"));
        assert!(uri.contains("v=1"));
        assert!(uri.contains("ic=3"));
    }
}
