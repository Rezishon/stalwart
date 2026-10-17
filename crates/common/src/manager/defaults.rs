/*
 * SPDX-FileCopyrightText: 2020 Stalwart Labs LLC <hello@stalw.art>
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
 */

use crate::auth::permissions::DefaultPermissions;
use aws_lc_rs::{
    rand::SystemRandom,
    signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair},
};
use registry::{
    schema::{
        enums::*,
        prelude::{ObjectType, SocketAddr},
        structs::*,
    },
    types::{duration::Duration, error::Error, list::List, map::Map},
};
use std::str::FromStr;
use store::{
    rand::{RngExt, distr::Alphanumeric, rng},
    registry::{
        bootstrap::Bootstrap,
        write::{RegistryWrite, RegistryWriteResult},
    },
};

pub const ASN_IPV4: &str =
    "https://github.com/sapics/ip-location-db/releases/download/latest/origin-asn-ipv4.csv";
pub const ASN_IPV6: &str =
    "https://github.com/sapics/ip-location-db/releases/download/latest/origin-asn-ipv6.csv";
pub const GEO_IPV4: &str =
    "https://github.com/sapics/ip-location-db/releases/download/latest/user-country-ipv4.csv";
pub const GEO_IPV6: &str =
    "https://github.com/sapics/ip-location-db/releases/download/latest/user-country-ipv6.csv";

pub trait BootstrapDefaults {
    fn insert_safe_defaults(&mut self) -> impl Future<Output = ()> + Send;
}

impl BootstrapDefaults for Bootstrap {
    async fn insert_safe_defaults(&mut self) {
        if let Err(error) = insert_safe_defaults(self).await {
            self.errors.push(Error::Internal {
                object_id: None,
                error,
            });
        }
    }
}

async fn insert_safe_defaults(bp: &mut Bootstrap) -> trc::Result<()> {
    let is_recovery_mode = bp.registry.is_recovery_mode();
    let is_bootstrap_mode = bp.registry.is_bootstrap_mode();

    if is_bootstrap_mode {
        #[cfg(not(any(feature = "dev_mode", feature = "test_mode")))]
        if bp.registry.count_object(ObjectType::SystemSettings).await? == 0 {
            bp.registry
                .write(RegistryWrite::insert(
                    &SystemSettings {
                        default_hostname: bp.registry.local_hostname().to_string(),
                        ..Default::default()
                    }
                    .into(),
                ))
                .await?;
        }

        return Ok(());
    }

    if is_recovery_mode {
        return Ok(());
    }

    if bp.registry.count_object(ObjectType::MtaQueueQuota).await? == 0 {
        bp.registry
            .write(RegistryWrite::insert(
                &MtaQueueQuota {
                    description: "Global queue quota".to_string().into(),
                    enable: true,
                    messages: 100000.into(),
                    size: 10737418240.into(),
                    ..Default::default()
                }
                .into(),
            ))
            .await?;
    }

    if bp
        .registry
        .count_object(ObjectType::MtaInboundThrottle)
        .await?
        == 0
    {
        for object in [
            MtaInboundThrottle {
                description: "Sender IP throttle".to_string(),
                enable: true,
                key: Map::new(vec![MtaInboundThrottleKey::RemoteIp]),
                rate: Rate {
                    count: 5,
                    period: Duration::from_millis(1000),
                },
                ..Default::default()
            },
            MtaInboundThrottle {
                description: "Sender address to recipient throttle".to_string(),
                enable: true,
                key: Map::new(vec![
                    MtaInboundThrottleKey::SenderDomain,
                    MtaInboundThrottleKey::Rcpt,
                ]),
                rate: Rate {
                    count: 25,
                    period: Duration::from_millis(60 * 60 * 1000),
                },
                ..Default::default()
            },
        ] {
            bp.registry
                .write(RegistryWrite::insert(&object.into()))
                .await?;
        }
    }

    if bp
        .registry
        .count_object(ObjectType::MtaVirtualQueue)
        .await?
        == 0
        && bp
            .registry
            .count_object(ObjectType::MtaDeliverySchedule)
            .await?
            == 0
    {
        for (id, object) in [
            MtaVirtualQueue {
                description: "Local delivery queue".to_string().into(),
                name: "local".into(),
                threads_per_node: 25,
            },
            MtaVirtualQueue {
                description: "Remote delivery queue".to_string().into(),
                name: "remote".into(),
                threads_per_node: 50,
            },
            MtaVirtualQueue {
                description: "Delivery Status Notification delivery queue"
                    .to_string()
                    .into(),
                name: "dsn".into(),
                threads_per_node: 5,
            },
            MtaVirtualQueue {
                description: "DMARC and TLS report delivery queue".to_string().into(),
                name: "report".into(),
                threads_per_node: 5,
            },
        ]
        .into_iter()
        .enumerate()
        {
            bp.registry
                .write(RegistryWrite::insert_with_id(
                    (id as u64).into(),
                    &object.into(),
                ))
                .await?;
        }

        for (id, object) in [
            MtaDeliverySchedule {
                name: "local".into(),
                description: "Local delivery schedule".to_string().into(),
                expiry: MtaDeliveryExpiration::Ttl(MtaDeliveryExpirationTtl {
                    expire: Duration::from_millis(3 * 24 * 60 * 60 * 1000),
                }),
                notify: MtaDeliveryScheduleIntervalsOrDefault::Default,
                retry: MtaDeliveryScheduleIntervalsOrDefault::Default,
                queue_id: 0u64.into(),
            },
            MtaDeliverySchedule {
                name: "remote".into(),
                description: "Remote delivery schedule".to_string().into(),
                expiry: MtaDeliveryExpiration::Ttl(MtaDeliveryExpirationTtl {
                    expire: Duration::from_millis(3 * 24 * 60 * 60 * 1000),
                }),
                notify: MtaDeliveryScheduleIntervalsOrDefault::Default,
                retry: MtaDeliveryScheduleIntervalsOrDefault::Default,
                queue_id: 1u64.into(),
            },
            MtaDeliverySchedule {
                name: "dsn".into(),
                description: "Delivery Status Notification delivery schedule"
                    .to_string()
                    .into(),
                expiry: MtaDeliveryExpiration::Attempts(MtaDeliveryExpirationAttempts {
                    max_attempts: 10,
                }),
                notify: MtaDeliveryScheduleIntervalsOrDefault::Default,
                retry: MtaDeliveryScheduleIntervalsOrDefault::Custom(
                    MtaDeliveryScheduleIntervals {
                        intervals: List::from_iter([
                            MtaDeliveryScheduleInterval {
                                duration: Duration::from_millis(15 * 60 * 1000),
                            },
                            MtaDeliveryScheduleInterval {
                                duration: Duration::from_millis(30 * 60 * 1000),
                            },
                            MtaDeliveryScheduleInterval {
                                duration: Duration::from_millis(60 * 60 * 1000),
                            },
                            MtaDeliveryScheduleInterval {
                                duration: Duration::from_millis(2 * 60 * 60 * 1000),
                            },
                        ]),
                    },
                ),
                queue_id: 2u64.into(),
            },
            MtaDeliverySchedule {
                name: "report".into(),
                description: "DMARC and TLS report delivery schedule".to_string().into(),
                expiry: MtaDeliveryExpiration::Attempts(MtaDeliveryExpirationAttempts {
                    max_attempts: 8,
                }),
                notify: MtaDeliveryScheduleIntervalsOrDefault::Default,
                retry: MtaDeliveryScheduleIntervalsOrDefault::Custom(
                    MtaDeliveryScheduleIntervals {
                        intervals: List::from_iter([
                            MtaDeliveryScheduleInterval {
                                duration: Duration::from_millis(30 * 60 * 1000),
                            },
                            MtaDeliveryScheduleInterval {
                                duration: Duration::from_millis(60 * 60 * 1000),
                            },
                            MtaDeliveryScheduleInterval {
                                duration: Duration::from_millis(2 * 60 * 60 * 1000),
                            },
                        ]),
                    },
                ),
                queue_id: 3u64.into(),
            },
        ]
        .into_iter()
        .enumerate()
        {
            bp.registry
                .write(RegistryWrite::insert_with_id(
                    (id as u64).into(),
                    &object.into(),
                ))
                .await?;
        }
    }

    if bp.registry.count_object(ObjectType::MtaTlsStrategy).await? == 0 {
        for object in [
            MtaTlsStrategy {
                name: "invalid-tls".into(),
                description: "Allow invalid TLS certificates".to_string().into(),
                allow_invalid_certs: true,
                ..Default::default()
            },
            MtaTlsStrategy {
                name: "default".into(),
                description: "Default TLS settings".to_string().into(),
                allow_invalid_certs: false,
                ..Default::default()
            },
        ] {
            bp.registry
                .write(RegistryWrite::insert(&object.into()))
                .await?;
        }
    }

    if bp.registry.count_object(ObjectType::MtaRoute).await? == 0 {
        for object in [
            MtaRoute::Mx(MtaRouteMx {
                description: "MX delivery route".to_string().into(),
                ip_lookup_strategy: MtaIpStrategy::V4ThenV6,
                max_multihomed: 2,
                max_mx_hosts: 2,
                name: "mx".into(),
            }),
            MtaRoute::Local(MtaRouteCommon {
                description: "Local delivery route".to_string().into(),
                name: "local".into(),
            }),
        ] {
            bp.registry
                .write(RegistryWrite::insert(&object.into()))
                .await?;
        }
    }

    if bp
        .registry
        .count_object(ObjectType::MtaConnectionStrategy)
        .await?
        == 0
    {
        bp.registry
            .write(RegistryWrite::insert(
                &MtaConnectionStrategy {
                    name: "default".into(),
                    description: "Default connection strategy".to_string().into(),
                    ..Default::default()
                }
                .into(),
            ))
            .await?;
    }

    if bp.registry.count_object(ObjectType::OidcProvider).await? == 0 {
        let pkcs8_doc =
            EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &SystemRandom::new())
                .map_err(|err| {
                    trc::EventType::Server(trc::ServerEvent::Startup)
                        .into_err()
                        .reason(err)
                        .caused_by(trc::location!())
                })?;
        let signature_pem = pem::encode(&pem::Pem::new("PRIVATE KEY", pkcs8_doc.as_ref()));

        bp.registry
            .write(RegistryWrite::insert(
                &OidcProvider {
                    encryption_key: SecretKey::Value(SecretKeyValue {
                        secret: rng()
                            .sample_iter(Alphanumeric)
                            .take(64)
                            .map(char::from)
                            .collect::<String>(),
                    }),
                    signature_key: SecretText::Text(SecretTextValue {
                        secret: signature_pem,
                    }),
                    signature_algorithm: JwtSignatureAlgorithm::Es256,
                    ..Default::default()
                }
                .into(),
            ))
            .await?;

        // Generate a Web Push VAPID signing key (RFC 9749)
        if bp.registry.count_object(ObjectType::Jmap).await? == 0 {
            match crate::network::webpush::generate_pkcs8_pem() {
                Ok(web_push_pem) => {
                    bp.registry
                        .write(RegistryWrite::insert(
                            &Jmap {
                                web_push_key: SecretTextOptional::Text(SecretTextValue {
                                    secret: web_push_pem,
                                }),
                                ..Default::default()
                            }
                            .into(),
                        ))
                        .await?;
                }
                Err(err) => {
                    trc::event!(
                        Server(trc::ServerEvent::Startup),
                        Details = "Failed to generate Web Push VAPID key",
                        Reason = err
                    );
                }
            }
        }
    }

    if bp.registry.count_object(ObjectType::Role).await? == 0 {
        let permissions = DefaultPermissions::default();
        let mut role_ids = Vec::with_capacity(4);

        for role in [
            Role {
                description: "User".into(),
                enabled_permissions: Map::new(permissions.user),
                ..Default::default()
            },
            Role {
                description: "Group".into(),
                enabled_permissions: Map::new(permissions.group),
                ..Default::default()
            },
            Role {
                description: "Tenant Administrator".into(),
                enabled_permissions: Map::new(permissions.tenant),
                ..Default::default()
            },
            Role {
                description: "System Administrator".into(),
                enabled_permissions: Map::new(permissions.superuser),
                ..Default::default()
            },
        ] {
            match bp
                .registry
                .write(RegistryWrite::insert(&role.into()))
                .await?
            {
                RegistryWriteResult::Success(id) => role_ids.push(id),
                err => {
                    bp.build_error(
                        ObjectType::Role.singleton(),
                        format!("Failed to insert default role: {err}"),
                    );
                }
            }
        }

        if bp.registry.count_object(ObjectType::Authentication).await? == 0 && role_ids.len() == 4 {
            bp.registry
                .write(RegistryWrite::insert(
                    &Authentication {
                        default_user_role_ids: Map::new(vec![role_ids[0]]),
                        default_group_role_ids: Map::new(vec![role_ids[1]]),
                        default_tenant_role_ids: Map::new(vec![role_ids[2], role_ids[0]]),
                        default_admin_role_ids: Map::new(vec![role_ids[3], role_ids[0]]),
                        ..Default::default()
                    }
                    .into(),
                ))
                .await?;
        }
    }

    if bp
        .registry
        .count_object(ObjectType::NetworkListener)
        .await?
        == 0
    {
        let get = |k: &str| std::env::var(k).ok();
        let use_tls = env_bool_from(get("STALWART_TLS").as_deref(), true);
        for (protocol, name, port, tls_implicit) in default_listener_specs_from(get) {
            bp.registry
                .write(RegistryWrite::insert(
                    &NetworkListener {
                        bind: Map::new(vec![
                            SocketAddr::from_str(&format!("[::]:{port}")).unwrap(),
                        ]),
                        name: name.to_string(),
                        protocol,
                        use_tls,
                        tls_implicit,
                        ..Default::default()
                    }
                    .into(),
                ))
                .await?;
        }
    }

    #[cfg(not(any(feature = "dev_mode", feature = "test_mode")))]
    if bp.registry.count_object(ObjectType::Asn).await? == 0 {
        bp.registry
            .write(RegistryWrite::insert(
                &Asn::Resource(AsnResource {
                    asn_urls: Map::new(vec![ASN_IPV4.into(), ASN_IPV6.into()]),
                    geo_urls: Map::new(vec![GEO_IPV4.into(), GEO_IPV6.into()]),
                    max_size: 104857600,
                    expires: Duration::from_millis(24 * 60 * 60 * 1000),
                    timeout: Duration::from_millis(5 * 60 * 1000),
                    ..Default::default()
                })
                .into(),
            ))
            .await?;
    }

    #[cfg(not(feature = "test_mode"))]
    if bp.registry.count_object(ObjectType::TracingStore).await? == 0 {
        bp.registry
            .write(RegistryWrite::insert(&TracingStore::Default.into()))
            .await?;
    }

    #[cfg(not(feature = "test_mode"))]
    if bp.registry.count_object(ObjectType::MetricsStore).await? == 0 {
        bp.registry
            .write(RegistryWrite::insert(&MetricsStore::Default.into()))
            .await?;
    }

    if bp.registry.count_object(ObjectType::Tracer).await? == 0 {
        bp.registry
            .write(RegistryWrite::insert(
                &Tracer::Log(TracerLog {
                    enable: true,
                    ansi: false,
                    prefix: "stalwart.log".into(),
                    rotate: LogRotateFrequency::Daily,
                    path: "/var/log/stalwart".into(),
                    ..Default::default()
                })
                .into(),
            ))
            .await?;
    }

    {
        use types::id::Id;

        let sys_domain = bp
            .registry
            .object::<SystemSettings>(Id::singleton())
            .await?
            .map(|s| s.default_domain_id)
            .filter(Id::is_valid);

        if let Some(old) = bp
            .registry
            .get(ObjectType::DeltaChat.singleton())
            .await?
        {
            let mut dc = DeltaChat::from(old.clone());
            if !dc.domain_id.is_valid()
                && let Some(domain_id) = sys_domain
            {
                dc.domain_id = domain_id;
                let new_object = dc.into();
                bp.registry
                    .write(RegistryWrite::update(Id::singleton(), &new_object, &old))
                    .await?;
            }
        } else {
            let mut dc = delta_chat_from_env();
            if let Some(domain_id) = sys_domain {
                dc.domain_id = domain_id;
            }
            bp.registry
                .write(RegistryWrite::insert(&dc.into()))
                .await?;
        }
    }

    #[cfg(not(feature = "test_mode"))]
    {
        use store::write::BatchBuilder;
        use types::id::Id;

        if bp.registry.count_object(ObjectType::SpamRule).await? == 0
            && bp
                .registry
                .object::<SpamSettings>(Id::singleton())
                .await?
                .is_none_or(|spam| spam.spam_filter_rules_url.is_some())
        {
            let mut batch = BatchBuilder::new();
            batch.schedule_task(Task::SpamFilterMaintenance(TaskSpamFilterMaintenance {
                maintenance_type: TaskSpamFilterMaintenanceType::UpdateRules,
                status: TaskStatus::now(),
            }));
            bp.data_store.write(batch.build_all()).await?;
        }
    }

    Ok(())
}



pub(crate) fn delta_chat_from_get(get: impl Fn(&str) -> Option<String>) -> DeltaChat {
    let mut dc = DeltaChat::default();
    dc.imap_host = env_str_from(get("STALWART_DC_IMAP_HOST").as_deref(), "");
    dc.imap_port = u64::from(env_u16_from(
        get("STALWART_DC_IMAP_PORT").as_deref(),
        env_u16_from(get("STALWART_LISTEN_IMAP").as_deref(), 993),
    ));
    dc.imap_security = match get("STALWART_DC_IMAP_SECURITY").as_deref().map(str::trim) {
        Some(s @ ("ssl" | "starttls" | "default" | "plain")) => s.to_string(),
        _ => "ssl".into(),
    };
    dc.smtp_host = env_str_from(get("STALWART_DC_SMTP_HOST").as_deref(), "");
    dc.smtp_port = u64::from(env_u16_from(
        get("STALWART_DC_SMTP_PORT").as_deref(),
        env_u16_from(get("STALWART_LISTEN_SUBMISSIONS").as_deref(), 465),
    ));
    dc.smtp_security = match get("STALWART_DC_SMTP_SECURITY").as_deref().map(str::trim) {
        Some(s @ ("ssl" | "starttls" | "default" | "plain")) => s.to_string(),
        _ => "ssl".into(),
    };
    dc.certificate_checks = match get("STALWART_DC_IC").as_deref().map(str::trim) {
        Some(s @ ("0" | "1" | "3")) => s.to_string(),
        _ => "3".into(),
    };
    dc
}

pub(crate) fn delta_chat_from_env() -> DeltaChat {
    delta_chat_from_get(|k| std::env::var(k).ok())
}

pub(crate) fn default_listener_specs_from(
    get: impl Fn(&str) -> Option<String>,
) -> Vec<(NetworkListenerProtocol, &'static str, u16, bool)> {
    let use_tls = env_bool_from(get("STALWART_TLS").as_deref(), true);
    const ROWS: &[(NetworkListenerProtocol, &str, &str, u16, bool)] = &[
        (NetworkListenerProtocol::Smtp, "smtp", "STALWART_LISTEN_SMTP", 25, false),
        (NetworkListenerProtocol::Smtp, "submission", "STALWART_LISTEN_SUBMISSION", 587, false),
        (NetworkListenerProtocol::Smtp, "submissions", "STALWART_LISTEN_SUBMISSIONS", 465, true),
        (NetworkListenerProtocol::Imap, "imaps", "STALWART_LISTEN_IMAP", 993, true),
        (NetworkListenerProtocol::Pop3, "pop3s", "STALWART_LISTEN_POP3", 995, true),
        (NetworkListenerProtocol::ManageSieve, "sieve", "STALWART_LISTEN_SIEVE", 4190, false),
        (NetworkListenerProtocol::Http, "https", "STALWART_LISTEN_HTTPS", 443, true),
        (NetworkListenerProtocol::Http, "http", "STALWART_LISTEN_HTTP", 8080, false),
    ];
    ROWS.iter()
        .filter_map(|&(protocol, name, key, default, tls_implicit)| {
            let port = env_u16_from(get(key).as_deref(), default);
            if port == 0 {
                return None;
            }
            Some((protocol, name, port, use_tls && tls_implicit))
        })
        .collect()
}

pub(crate) fn env_u16_from(raw: Option<&str>, default: u16) -> u16 {
    let Some(s) = raw.map(str::trim).filter(|s| !s.is_empty()) else {
        return default;
    };
    s.parse().unwrap_or_else(|_| {
        trc::event!(
            Server(trc::ServerEvent::Startup),
            Details = format!("invalid port {s:?}, using {default}")
        );
        default
    })
}

pub(crate) fn env_bool_from(raw: Option<&str>, default: bool) -> bool {
    match raw.map(str::trim) {
        Some("1" | "true" | "TRUE" | "yes" | "YES") => true,
        Some("0" | "false" | "FALSE" | "no" | "NO") => false,
        Some(other) if !other.is_empty() => {
            trc::event!(
                Server(trc::ServerEvent::Startup),
                Details = format!("invalid bool {other:?}, using {default}")
            );
            default
        }
        _ => default,
    }
}

pub(crate) fn env_str_from(raw: Option<&str>, default: &str) -> String {
    match raw.map(str::trim).filter(|s| !s.is_empty()) {
        Some(s) => s.to_string(),
        None => default.to_string(),
    }
}

pub(crate) fn recovery_http_port_from(recovery: Option<&str>, listen_http: Option<&str>) -> u16 {
    let p = env_u16_from(recovery, env_u16_from(listen_http, 8080));
    if p == 0 { 8080 } else { p }
}

pub(crate) fn recovery_http_port() -> u16 {
    recovery_http_port_from(
        std::env::var("STALWART_RECOVERY_MODE_PORT").ok().as_deref(),
        std::env::var("STALWART_LISTEN_HTTP").ok().as_deref(),
    )
}

pub(crate) fn env_u16(key: &str, default: u16) -> u16 {
    env_u16_from(std::env::var(key).ok().as_deref(), default)
}

pub(crate) fn env_bool(key: &str, default: bool) -> bool {
    env_bool_from(std::env::var(key).ok().as_deref(), default)
}

pub(crate) fn env_str(key: &str, default: &str) -> String {
    env_str_from(std::env::var(key).ok().as_deref(), default)
}


#[cfg(test)]
mod env_parse_tests {
    use super::{
        default_listener_specs_from, delta_chat_from_get, env_bool_from, env_str_from,
        env_u16_from, recovery_http_port_from,
    };

    #[test]
    fn env_u16_default_on_empty() {
        assert_eq!(env_u16_from(None, 25), 25);
        assert_eq!(env_u16_from(Some(""), 25), 25);
        assert_eq!(env_u16_from(Some("nope"), 25), 25);
    }

    #[test]
    fn env_u16_zero_and_value() {
        assert_eq!(env_u16_from(Some("0"), 25), 0);
        assert_eq!(env_u16_from(Some("587"), 25), 587);
        assert_eq!(env_u16_from(Some("65535"), 25), 65535);
        assert_eq!(env_u16_from(Some("65536"), 25), 25);
    }

    #[test]
    fn env_bool_and_str() {
        assert!(env_bool_from(Some("true"), false));
        assert!(!env_bool_from(Some("0"), true));
        assert!(env_bool_from(None, true));
        assert_eq!(env_str_from(Some(" mail.example "), "x"), "mail.example");
        assert_eq!(env_str_from(Some(""), "ssl"), "ssl");
    }

    #[test]
    fn default_listeners_include_submission_587() {
        let specs = default_listener_specs_from(|k| match k {
            "STALWART_TLS" => Some("true".into()),
            _ => None,
        });
        assert!(specs.iter().any(|s| s.1 == "submission" && s.2 == 587));
        assert!(specs.iter().any(|s| s.1 == "submissions" && s.2 == 465));
        assert_eq!(specs.len(), 8);
    }

    #[test]
    fn default_listeners_skip_zero_and_honor_tls_off() {
        let specs = default_listener_specs_from(|k| match k {
            "STALWART_LISTEN_POP3" => Some("0".into()),
            "STALWART_LISTEN_HTTP" => Some("9080".into()),
            "STALWART_TLS" => Some("false".into()),
            _ => None,
        });
        assert!(!specs.iter().any(|s| s.1 == "pop3s"));
        let http = specs.iter().find(|s| s.1 == "http").unwrap();
        assert_eq!(http.2, 9080);
        assert!(specs.iter().all(|s| !s.3));
    }

    #[test]
    fn recovery_http_port_fallback() {
        assert_eq!(recovery_http_port_from(None, None), 8080);
        assert_eq!(recovery_http_port_from(Some("9090"), Some("8080")), 9090);
        assert_eq!(recovery_http_port_from(None, Some("9080")), 9080);
        assert_eq!(recovery_http_port_from(Some("0"), None), 8080);
    }

    #[test]
    fn delta_chat_from_env_overlays_ports() {
        let dc = delta_chat_from_get(|k| match k {
            "STALWART_DC_IMAP_PORT" => Some("1993".into()),
            "STALWART_DC_IC" => Some("1".into()),
            "STALWART_DC_IMAP_HOST" => Some("mail.example.org".into()),
            _ => None,
        });
        assert_eq!(dc.imap_port, 1993u64);
        assert_eq!(dc.certificate_checks, "1");
        assert_eq!(dc.imap_host, "mail.example.org");
        assert_eq!(dc.smtp_port, 465u64);
    }

    #[test]
    fn delta_chat_from_env_rejects_bad_security() {
        let dc = delta_chat_from_get(|k| match k {
            "STALWART_DC_IMAP_SECURITY" => Some("bogus".into()),
            "STALWART_DC_IC" => Some("9".into()),
            _ => None,
        });
        assert_eq!(dc.imap_security, "ssl");
        assert_eq!(dc.certificate_checks, "3");
    }
}
