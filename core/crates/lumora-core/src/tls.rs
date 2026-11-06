//! TLS 1.3 for QUIC where the certificate *is* the device identity.
//!
//! Each node presents a self-signed X.509 certificate whose public key is its
//! Ed25519 identity key. Instead of CAs we pin keys:
//! * client → server: the dialer knows which `PeerId` it wants; any other key aborts
//!   the handshake (MITM by a relay / signaling server is impossible).
//! * server → client: client certificates are mandatory; the server extracts the
//!   key and the application layer authorises it (friend list, remote password...).

use crate::devices::DeviceCert;
use crate::identity::{Identity, PeerId};
use anyhow::{anyhow, Result};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{verify_tls13_signature, CryptoProvider, WebPkiSupportedAlgorithms};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, UnixTime};
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::{DigitallySignedStruct, DistinguishedName, SignatureScheme};
use std::sync::Arc;

pub const ALPN: &[u8] = b"lumora/1";

fn provider() -> Arc<CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

/// Self-signed certificate for this device. A secondary device also carries its
/// [`DeviceCert`] as an extra SAN URI (`lumora:devcert:v1:…`): older peers ignore it and
/// still pin the device key; newer ones learn the account before any message arrives.
pub fn make_cert(id: &Identity, devcert: Option<&DeviceCert>) -> Result<(CertificateDer<'static>, PrivateKeyDer<'static>)> {
    let der = id.pkcs8_der();
    let pkcs8 = PrivatePkcs8KeyDer::from(der.to_vec());
    let kp = rcgen::KeyPair::from_pkcs8_der_and_sign_algo(&pkcs8, &rcgen::PKCS_ED25519)?;
    let mut params = rcgen::CertificateParams::new(vec!["lumora.peer".to_string()])?;
    if let Some(c) = devcert {
        params.subject_alt_names.push(rcgen::SanType::URI(rcgen::string::Ia5String::try_from(c.to_san())?));
    }
    params.distinguished_name = rcgen::DistinguishedName::new();
    params.not_before = rcgen::date_time_ymd(2020, 1, 1);
    params.not_after = rcgen::date_time_ymd(2100, 1, 1);
    let cert = params.self_signed(&kp)?;
    Ok((cert.der().clone(), PrivateKeyDer::Pkcs8(pkcs8)))
}

/// Extract the Ed25519 key from a peer certificate.
pub fn peer_id_from_cert(cert: &CertificateDer<'_>) -> Result<PeerId> {
    let (_, parsed) = x509_parser::parse_x509_certificate(cert.as_ref()).map_err(|e| anyhow!("x509: {e}"))?;
    let spki = &parsed.tbs_certificate.subject_pki;
    // OID 1.3.101.112 = Ed25519
    if spki.algorithm.algorithm.to_id_string() != "1.3.101.112" {
        return Err(anyhow!("peer certificate is not Ed25519"));
    }
    let key = spki.subject_public_key.data.as_ref();
    let arr: [u8; 32] = key.try_into().map_err(|_| anyhow!("bad key length"))?;
    Ok(PeerId(arr))
}

#[derive(Debug)]
struct PinnedServerVerifier {
    algs: WebPkiSupportedAlgorithms,
    /// `None` = accept any key (used for relays / LAN probing where the key is learned).
    expected: Option<PeerId>,
}

impl ServerCertVerifier for PinnedServerVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let got = peer_id_from_cert(end_entity).map_err(|e| rustls::Error::General(e.to_string()))?;
        if let Some(exp) = self.expected {
            if exp != got {
                return Err(rustls::Error::General("peer key mismatch (possible MITM)".into()));
            }
        }
        Ok(ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        _m: &[u8],
        _c: &CertificateDer<'_>,
        _d: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::General("TLS1.2 not allowed".into()))
    }
    fn verify_tls13_signature(
        &self,
        m: &[u8],
        c: &CertificateDer<'_>,
        d: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(m, c, d, &self.algs)
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        vec![SignatureScheme::ED25519]
    }
}

#[derive(Debug)]
struct AnyClientVerifier {
    algs: WebPkiSupportedAlgorithms,
}

impl ClientCertVerifier for AnyClientVerifier {
    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        &[]
    }
    fn verify_client_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _now: UnixTime,
    ) -> Result<ClientCertVerified, rustls::Error> {
        peer_id_from_cert(end_entity).map_err(|e| rustls::Error::General(e.to_string()))?;
        Ok(ClientCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        _m: &[u8],
        _c: &CertificateDer<'_>,
        _d: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::General("TLS1.2 not allowed".into()))
    }
    fn verify_tls13_signature(
        &self,
        m: &[u8],
        c: &CertificateDer<'_>,
        d: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(m, c, d, &self.algs)
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        vec![SignatureScheme::ED25519]
    }
}

pub fn transport_config() -> Arc<quinn::TransportConfig> {
    let mut t = quinn::TransportConfig::default();
    t.keep_alive_interval(Some(std::time::Duration::from_secs(10)));
    t.max_idle_timeout(Some(std::time::Duration::from_secs(40).try_into().unwrap()));
    t.max_concurrent_bidi_streams(16u32.into());
    t.max_concurrent_uni_streams(96u32.into());
    t.datagram_receive_buffer_size(Some(2 * 1024 * 1024));
    t.datagram_send_buffer_size(2 * 1024 * 1024);
    t.stream_receive_window((8u32 * 1024 * 1024).into());
    t.receive_window((32u32 * 1024 * 1024).into());
    t.send_window(32 * 1024 * 1024);
    t.initial_rtt(std::time::Duration::from_millis(150));
    // BBR copes much better with lossy Wi-Fi/4G than the default NewReno.
    t.congestion_controller_factory(Arc::new(quinn::congestion::BbrConfig::default()));
    Arc::new(t)
}

pub fn server_config(id: &Identity, devcert: Option<&DeviceCert>) -> Result<quinn::ServerConfig> {
    let p = provider();
    let (cert, key) = make_cert(id, devcert)?;
    let mut tls = rustls::ServerConfig::builder_with_provider(p.clone())
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .with_client_cert_verifier(Arc::new(AnyClientVerifier { algs: p.signature_verification_algorithms }))
        .with_single_cert(vec![cert], key)?;
    tls.alpn_protocols = vec![ALPN.to_vec()];
    tls.max_early_data_size = 0;
    let qc = quinn::crypto::rustls::QuicServerConfig::try_from(tls)?;
    let mut sc = quinn::ServerConfig::with_crypto(Arc::new(qc));
    sc.transport_config(transport_config());
    sc.migration(true);
    Ok(sc)
}

pub fn client_config(id: &Identity, devcert: Option<&DeviceCert>, expected: Option<PeerId>) -> Result<quinn::ClientConfig> {
    let p = provider();
    let (cert, key) = make_cert(id, devcert)?;
    let mut tls = rustls::ClientConfig::builder_with_provider(p.clone())
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(PinnedServerVerifier {
            algs: p.signature_verification_algorithms,
            expected,
        }))
        .with_client_auth_cert(vec![cert], key)?;
    tls.alpn_protocols = vec![ALPN.to_vec()];
    let qc = quinn::crypto::rustls::QuicClientConfig::try_from(tls)?;
    let mut cc = quinn::ClientConfig::new(Arc::new(qc));
    cc.transport_config(transport_config());
    Ok(cc)
}

/// Identity of the remote side of an established connection.
pub fn remote_peer(conn: &quinn::Connection) -> Result<PeerId> {
    Ok(remote_identity(conn)?.0)
}

/// Remote device key plus its device certificate, if it presented a valid one for
/// exactly this key (a secondary device of some account).
pub fn remote_identity(conn: &quinn::Connection) -> Result<(PeerId, Option<DeviceCert>)> {
    let ident = conn.peer_identity().ok_or_else(|| anyhow!("no peer identity"))?;
    let certs = ident
        .downcast::<Vec<CertificateDer<'static>>>()
        .map_err(|_| anyhow!("unexpected identity type"))?;
    let first = certs.first().ok_or_else(|| anyhow!("empty chain"))?;
    identity_from_cert(first)
}

pub fn identity_from_cert(cert: &CertificateDer<'_>) -> Result<(PeerId, Option<DeviceCert>)> {
    let dev = peer_id_from_cert(cert)?;
    let (_, parsed) = x509_parser::parse_x509_certificate(cert.as_ref()).map_err(|e| anyhow!("x509: {e}"))?;
    let mut found = None;
    if let Ok(Some(san)) = parsed.subject_alternative_name() {
        for n in san.value.general_names.iter() {
            if let x509_parser::extensions::GeneralName::URI(u) = n {
                if let Some(c) = DeviceCert::from_san(u) {
                    if c.device == dev && c.verify() {
                        found = Some(c);
                    }
                }
            }
        }
    }
    Ok((dev, found))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn devcert_rides_in_the_san() {
        let root = Identity::generate();
        let dev = Identity::generate();
        let c = DeviceCert::issue(&root, dev.peer_id(), 5, 0);
        let (der, _) = make_cert(&dev, Some(&c)).unwrap();
        let (k, got) = identity_from_cert(&der).unwrap();
        assert_eq!(k, dev.peer_id());
        assert_eq!(got, Some(c.clone()));
        // no SAN (primary / old peer)
        let (der2, _) = make_cert(&root, None).unwrap();
        assert_eq!(identity_from_cert(&der2).unwrap(), (root.peer_id(), None));
        // a cert for another device in the SAN is ignored (can't claim someone's account)
        let (der3, _) = make_cert(&Identity::generate(), Some(&c)).unwrap();
        assert!(identity_from_cert(&der3).unwrap().1.is_none());
    }
}
