//! Tests for the pairing host. The "phone" here follows idevice's own model of
//! pair-setup (its SRP client, then the HKDF, ChaCha20-Poly1305 and Ed25519 steps
//! of M5/M6), so they show our wrapper drives idevice's responder through the
//! whole exchange to a pairing file idevice reads back. Whether iOS accepts the
//! host is only known on a device.

use std::ffi::{CStr, CString, c_char, c_void};
use std::path::PathBuf;
use std::ptr::{null, null_mut};
use std::sync::{Arc, mpsc};
use std::time::Duration;

use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
use chacha20poly1305::aead::{Aead, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, KeyInit, Nonce};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use hkdf::Hkdf;
use idevice::remote_pairing::{RpPairingFile, RpPairingSocket, RpPairingSocketProvider};
use idevice_srp::{client::SrpClient, groups::G_3072};
use rand::RngCore;
use serde_json::json;
use sha2::Sha512;
use tokio::net::TcpStream;

use crate::pairing::*;

// Pair-setup TLV types.
const METHOD: u8 = 0x00;
const IDENTIFIER: u8 = 0x01;
const SALT: u8 = 0x02;
const PUBLIC_KEY: u8 = 0x03;
const PROOF: u8 = 0x04;
const ENCRYPTED_DATA: u8 = 0x05;
const STATE: u8 = 0x06;
const ERROR: u8 = 0x07;
const SIGNATURE: u8 = 0x0a;
const INFO: u8 = 0x11;

const DISPLAY_NAME: &str = "Atelier Test";

/// TLV8, splitting values longer than 255 bytes into consecutive items.
fn tlv(items: &[(u8, &[u8])]) -> Vec<u8> {
    let mut out = Vec::new();
    for &(kind, value) in items {
        if value.is_empty() {
            out.extend_from_slice(&[kind, 0]);
        }
        for chunk in value.chunks(255) {
            out.push(kind);
            out.push(chunk.len() as u8);
            out.extend_from_slice(chunk);
        }
    }
    out
}

fn parse_tlv(bytes: &[u8]) -> Vec<(u8, Vec<u8>)> {
    let mut items = Vec::new();
    let mut i = 0;
    while i + 2 <= bytes.len() {
        let (kind, len) = (bytes[i], bytes[i + 1] as usize);
        let end = (i + 2 + len).min(bytes.len());
        items.push((kind, bytes[i + 2..end].to_vec()));
        i = end;
    }
    items
}

/// A TLV field, with split items joined back together.
fn field(items: &[(u8, Vec<u8>)], kind: u8) -> Vec<u8> {
    items
        .iter()
        .filter(|(k, _)| *k == kind)
        .flat_map(|(_, v)| v.clone())
        .collect()
}

enum Opack<'a> {
    Str(&'a str),
    Data(&'a [u8]),
}

/// OPACK for a small dictionary of strings and data: what the phone's identity
/// info in M5 needs, encoded the way idevice decodes it.
fn opack_dict(entries: &[(&str, Opack)]) -> Vec<u8> {
    assert!(entries.len() < 15);
    let mut out = vec![0xE0 + entries.len() as u8];
    for (key, value) in entries {
        opack_item(&mut out, 0x40, 0x61, key.as_bytes());
        match value {
            Opack::Str(s) => opack_item(&mut out, 0x40, 0x61, s.as_bytes()),
            Opack::Data(d) => opack_item(&mut out, 0x70, 0x91, d),
        }
    }
    out
}

/// Up to 32 bytes, the length is part of the tag; up to 255, it's one byte after it.
fn opack_item(out: &mut Vec<u8>, inline_tag: u8, u8_len_tag: u8, bytes: &[u8]) {
    if bytes.len() <= 0x20 {
        out.push(inline_tag + bytes.len() as u8);
    } else {
        out.push(u8_len_tag);
        out.push(u8::try_from(bytes.len()).expect("item under 256 bytes"));
    }
    out.extend_from_slice(bytes);
}

fn hkdf32(secret: &[u8], salt: &[u8], info: &[u8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    Hkdf::<Sha512>::new(Some(salt), secret)
        .expand(info, &mut out)
        .expect("HKDF expand");
    out
}

fn random<const N: usize>() -> [u8; N] {
    let mut bytes = [0u8; N];
    rand::rng().fill_bytes(&mut bytes);
    bytes
}

fn parse_txt(record: &[u8]) -> Vec<(String, String)> {
    let mut pairs = Vec::new();
    let mut i = 0;
    while i < record.len() {
        let len = record[i] as usize;
        let entry = std::str::from_utf8(&record[i + 1..i + 1 + len]).expect("UTF-8 TXT entry");
        let (key, value) = entry.split_once('=').expect("key=value");
        pairs.push((key.to_string(), value.to_string()));
        i += 1 + len;
    }
    pairs
}

fn at<'a>(value: &'a plist::Value, keys: &[&str]) -> Option<&'a plist::Value> {
    keys.iter()
        .try_fold(value, |v, k| v.as_dictionary()?.get(k))
}

fn test_runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
}

/// A host running on its own thread with a current-thread runtime, the way
/// `atelier_pair_session_run` runs it.
struct HostRun {
    advert: Advert,
    pins: mpsc::Receiver<String>,
    cancel: Arc<Cancel>,
    result: std::thread::JoinHandle<Result<Paired, PairError>>,
    out_path: PathBuf,
}

fn start_host(test: &str, deadline: Option<Duration>) -> HostRun {
    let out_path = std::env::temp_dir().join(format!(
        "atelier-pair-{test}-{}.plist",
        std::process::id()
    ));
    let _ = std::fs::remove_file(&out_path);
    let cancel = Arc::new(Cancel::default());
    let (advert_tx, advert_rx) = mpsc::channel();
    let (pin_tx, pin_rx) = mpsc::channel();

    let (host_out, host_cancel) = (out_path.clone(), cancel.clone());
    let result = std::thread::spawn(move || {
        test_runtime().block_on(host_once(
            DISPLAY_NAME,
            &host_out,
            &host_cancel,
            deadline,
            &|line| eprintln!("[host] {line}"),
            move |advert| {
                let _ = advert_tx.send(advert.clone());
            },
            move |pin| {
                let _ = pin_tx.send(pin.to_string());
            },
        ))
    });
    let advert = advert_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("host never advertised");
    HostRun {
        advert,
        pins: pin_rx,
        cancel,
        result,
        out_path,
    }
}

/// The phone's side of the conversation, as far as these tests need it.
struct Phone {
    sock: RpPairingSocket<TcpStream>,
    seq: usize,
}

impl Phone {
    async fn connect(port: u16) -> Self {
        let stream = TcpStream::connect(("127.0.0.1", port))
            .await
            .expect("connect to the host");
        Self {
            sock: RpPairingSocket::new(stream),
            seq: 0,
        }
    }

    async fn send(&mut self, value: serde_json::Value) {
        self.sock.send_plain(value, self.seq).await.expect("send");
        self.seq += 1;
    }

    async fn recv(&mut self) -> plist::Value {
        tokio::time::timeout(Duration::from_secs(10), self.sock.recv_plain())
            .await
            .expect("the host didn't answer")
            .expect("recv")
    }

    /// A first-time handshake (no pair-verify), so the host must offer pair-setup.
    async fn handshake(&mut self) {
        self.send(json!({
            "request": { "_0": { "handshake": { "_0": {
                "wireProtocolVersion": 26,
                "hostOptions": {},
            }}}}
        }))
        .await;
        let reply = self.recv().await;
        let allows = at(
            &reply,
            &["response", "_1", "handshake", "_0", "deviceOptions", "allowsPairSetup"],
        )
        .and_then(|v| v.as_boolean());
        assert_eq!(allows, Some(true), "handshake reply: {reply:?}");
    }

    async fn send_tlv(&mut self, data: &[u8], start_new_session: bool) {
        self.send(json!({
            "event": { "_0": { "pairingData": { "_0": {
                "data": B64.encode(data),
                "startNewSession": start_new_session,
                "kind": "setupManualPairing",
            }}}}
        }))
        .await;
    }

    async fn recv_tlv(&mut self) -> Vec<(u8, Vec<u8>)> {
        let message = self.recv().await;
        let data = at(&message, &["event", "_0", "pairingData", "_0", "data"])
            .and_then(|v| v.as_string())
            .expect("a pairingData event");
        parse_tlv(&B64.decode(data).expect("base64 TLV"))
    }

    /// Sends M1 and returns M2's salt and SRP public key.
    async fn start_pair_setup(&mut self) -> (Vec<u8>, Vec<u8>) {
        self.send_tlv(&tlv(&[(METHOD, &[0]), (STATE, &[1])]), true)
            .await;
        let m2 = self.recv_tlv().await;
        assert_eq!(field(&m2, STATE), [2]);
        let (salt, b_pub) = (field(&m2, SALT), field(&m2, PUBLIC_KEY));
        assert_eq!((salt.len(), b_pub.len()), (16, 384));
        (salt, b_pub)
    }
}

fn check_advert(advert: &Advert) {
    let txt = parse_txt(&advert.txt_record);
    let get = |key: &str| {
        txt.iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    };
    assert_eq!(get("name"), Some(DISPLAY_NAME));
    assert_eq!(get("identifier"), Some(advert.instance.as_str()));
    assert_eq!(get("model"), Some("Atelier"));
    let tag = get("authTag").expect("authTag");
    assert_eq!(B64.decode(tag).expect("base64 authTag").len(), 6);
    assert_eq!(advert.instance.len(), 36, "a UUID: {}", advert.instance);
    assert_ne!(advert.port, 0);
}

/// Drives pair-setup M3-M6 from the phone, after `start_pair_setup` has sent M1
/// and received M2's `(salt, b_pub)`. Returns the host identity the phone would
/// store (identifier and long-term public key) and the phone's altIRK, so the
/// caller can check them against the saved pairing file.
async fn finish_pair_setup(
    phone: &mut Phone,
    pin: &str,
    salt: &[u8],
    b_pub: &[u8],
) -> (Vec<u8>, [u8; 32], [u8; 16]) {
    // M3/M4: SRP with the code, as the phone does once the user has typed it.
    let srp = SrpClient::<Sha512>::new(&G_3072);
    let a = random::<32>();
    let verifier = srp
        .process_reply(&a, b"Pair-Setup", pin.as_bytes(), salt, b_pub, false)
        .expect("SRP");
    let a_pub = srp.compute_public_ephemeral(&a);
    phone
        .send_tlv(
            &tlv(&[(STATE, &[3]), (PUBLIC_KEY, &a_pub), (PROOF, verifier.proof())]),
            false,
        )
        .await;
    let m4 = phone.recv_tlv().await;
    assert_eq!(field(&m4, STATE), [4]);
    verifier
        .verify_server(&field(&m4, PROOF))
        .expect("the host's SRP proof");
    let session_key = verifier.key().to_vec();
    let cipher = ChaCha20Poly1305::new(Key::from_slice(&hkdf32(
        &session_key,
        b"Pair-Setup-Encrypt-Salt",
        b"Pair-Setup-Encrypt-Info",
    )));

    // M5: the phone's identity, encrypted with the SRP session key.
    let phone_key = SigningKey::from_bytes(&random::<32>());
    let phone_id = b"phone-pairing-identifier";
    let phone_ltpk = phone_key.verifying_key().to_bytes();
    let phone_x = hkdf32(
        &session_key,
        b"Pair-Setup-Controller-Sign-Salt",
        b"Pair-Setup-Controller-Sign-Info",
    );
    let phone_signature = phone_key.sign(&[&phone_x[..], phone_id, &phone_ltpk].concat());
    let phone_alt_irk = random::<16>();
    let info = opack_dict(&[
        ("accountID", Opack::Str("phone-account")),
        ("altIRK", Opack::Data(&phone_alt_irk)),
        ("model", Opack::Str("iPhone16,1")),
        ("name", Opack::Str("Test iPhone")),
        ("remotepairing_udid", Opack::Str("00008130-000A1B2C3D4E5F60")),
    ]);
    let m5_plain = tlv(&[
        (IDENTIFIER, phone_id),
        (PUBLIC_KEY, &phone_ltpk),
        (SIGNATURE, &phone_signature.to_bytes()),
        (INFO, &info),
    ]);
    let m5_sealed = cipher
        .encrypt(
            Nonce::from_slice(b"\0\0\0\0PS-Msg05"),
            Payload { msg: &m5_plain, aad: b"" },
        )
        .expect("encrypt M5");
    phone
        .send_tlv(&tlv(&[(STATE, &[5]), (ENCRYPTED_DATA, &m5_sealed)]), false)
        .await;

    // M6: the host's identity, which the phone checks before storing it.
    let m6 = phone.recv_tlv().await;
    assert_eq!(field(&m6, STATE), [6]);
    let m6_plain = cipher
        .decrypt(
            Nonce::from_slice(b"\0\0\0\0PS-Msg06"),
            Payload { msg: &field(&m6, ENCRYPTED_DATA), aad: b"" },
        )
        .expect("decrypt M6");
    let m6 = parse_tlv(&m6_plain);
    let host_id = field(&m6, IDENTIFIER);
    let host_ltpk: [u8; 32] = field(&m6, PUBLIC_KEY).try_into().expect("32-byte key");
    let host_signature =
        Signature::from_slice(&field(&m6, SIGNATURE)).expect("64-byte signature");
    let host_x = hkdf32(
        &session_key,
        b"Pair-Setup-Accessory-Sign-Salt",
        b"Pair-Setup-Accessory-Sign-Info",
    );
    VerifyingKey::from_bytes(&host_ltpk)
        .expect("valid key")
        .verify(&[&host_x[..], &host_id, &host_ltpk].concat(), &host_signature)
        .expect("the host's signature over its identity");
    (host_id, host_ltpk, phone_alt_irk)
}

#[test]
fn full_pairing_writes_a_file_idevice_reads_back() {
    let host = start_host("full", None);
    check_advert(&host.advert);

    let (host_id, host_ltpk, phone_alt_irk) = test_runtime().block_on(async {
        let mut phone = Phone::connect(host.advert.port).await;
        phone.handshake().await;
        let (salt, b_pub) = phone.start_pair_setup().await;
        let pin = host
            .pins
            .recv_timeout(Duration::from_secs(5))
            .expect("no code shown");
        assert!(pin.len() == 6 && pin.bytes().all(|b| b.is_ascii_digit()), "code {pin:?}");
        finish_pair_setup(&mut phone, &pin, &salt, &b_pub).await
    });

    let paired = host.result.join().unwrap().expect("the host reports success");
    assert_eq!(paired.device_name, "Test iPhone");
    assert_eq!(paired.device_model, "iPhone16,1");

    // The file is what route A reads: idevice must parse it, and it must hold
    // the identity the host gave the phone, plus the phone's altIRK.
    let bytes = std::fs::read(&host.out_path).expect("a pairing file");
    let file = RpPairingFile::from_bytes(&bytes).expect("idevice reads the file");
    assert_eq!(file.identifier.as_bytes(), host_id.as_slice());
    assert_eq!(file.identifier, host.advert.instance, "advertised as its identifier");
    assert_eq!(file.public_key_bytes(), host_ltpk);
    assert_eq!(file.e_private_key.verifying_key().to_bytes(), host_ltpk);
    assert_eq!(file.alt_irk.as_deref(), Some(&phone_alt_irk[..]));
    assert!(!partial_path(&host.out_path).exists());
    let _ = std::fs::remove_file(&host.out_path);
}

#[test]
fn a_connection_that_ends_before_the_code_doesnt_end_the_attempt() {
    let host = start_host("stray", None);
    let runtime = test_runtime();
    let phone = runtime.block_on(async {
        drop(
            TcpStream::connect(("127.0.0.1", host.advert.port))
                .await
                .unwrap(),
        );
        // The real phone, after it: the host must still be listening.
        let mut phone = Phone::connect(host.advert.port).await;
        phone.handshake().await;
        phone.start_pair_setup().await;
        phone
    });
    host.pins
        .recv_timeout(Duration::from_secs(5))
        .expect("a code after the stray connection");
    host.cancel.cancel();
    let result = host.result.join().unwrap();
    drop(phone);
    assert!(matches!(result, Err(PairError::Cancelled)), "{result:?}");
    assert!(!host.out_path.exists());
}

#[test]
fn a_wrong_code_fails_and_writes_nothing() {
    let host = start_host("wrong-code", None);
    let m4 = test_runtime().block_on(async {
        let mut phone = Phone::connect(host.advert.port).await;
        phone.handshake().await;
        let (salt, b_pub) = phone.start_pair_setup().await;
        let pin = host.pins.recv_timeout(Duration::from_secs(5)).unwrap();
        let wrong = if pin == "000000" { "000001" } else { "000000" };
        let srp = SrpClient::<Sha512>::new(&G_3072);
        let a = random::<32>();
        let verifier = srp
            .process_reply(&a, b"Pair-Setup", wrong.as_bytes(), &salt, &b_pub, false)
            .unwrap();
        let a_pub = srp.compute_public_ephemeral(&a);
        phone
            .send_tlv(
                &tlv(&[(STATE, &[3]), (PUBLIC_KEY, &a_pub), (PROOF, verifier.proof())]),
                false,
            )
            .await;
        phone.recv_tlv().await
    });
    assert_eq!(field(&m4, ERROR), [2], "authentication error to the phone");
    let result = host.result.join().unwrap();
    assert!(matches!(result, Err(PairError::Failed(_))), "{result:?}");
    assert!(!host.out_path.exists());
}

#[test]
fn cancel_ends_an_attempt_nobody_finishes() {
    let host = start_host("cancel", None);
    host.cancel.cancel();
    let result = host.result.join().unwrap();
    assert!(matches!(result, Err(PairError::Cancelled)), "{result:?}");
}

#[test]
fn a_cancel_before_the_run_starts_is_kept() {
    let cancel = Cancel::default();
    cancel.cancel();
    let path = std::env::temp_dir().join("atelier-pair-precancelled.plist");
    let result = test_runtime().block_on(host_once(
        DISPLAY_NAME,
        &path,
        &cancel,
        None,
        &|_| {},
        |_| {},
        |_| {},
    ));
    assert!(matches!(result, Err(PairError::Cancelled)), "{result:?}");
}

#[test]
fn the_deadline_ends_an_unfinished_attempt() {
    let host = start_host("deadline", Some(Duration::from_millis(200)));
    let result = host.result.join().unwrap();
    assert!(matches!(result, Err(PairError::TimedOut)), "{result:?}");
}

#[test]
fn every_attempt_gets_a_fresh_identity() {
    let first = start_host("fresh-1", None);
    let second = start_host("fresh-2", None);
    assert_ne!(first.advert.instance, second.advert.instance);
    for run in [first, second] {
        run.cancel.cancel();
        let _ = run.result.join();
    }
}

#[test]
fn txt_record_is_dns_wire_format() {
    let record = txt_record(&[
        ("a".into(), "1".into()),
        ("name".into(), "Atelier Spike".into()),
    ])
    .unwrap();
    assert_eq!(record, b"\x03a=1\x12name=Atelier Spike");
    assert!(txt_record(&[("k".into(), "v".repeat(300))]).is_err());
}

extern "C" fn record_advert(
    ctx: *mut c_void,
    instance: *const c_char,
    port: u16,
    _txt_record: *const u8,
    txt_len: usize,
) {
    let seen = unsafe { &*(ctx as *const mpsc::Sender<(String, u16, usize)>) };
    let instance = unsafe { CStr::from_ptr(instance) }.to_string_lossy().into_owned();
    let _ = seen.send((instance, port, txt_len));
}

#[test]
fn c_api_advertises_cancels_and_frees() {
    let (tx, rx) = mpsc::channel::<(String, u16, usize)>();
    let ctx = Box::into_raw(Box::new(tx)) as usize;
    let session = atelier_pair_session_new() as usize;
    let out = std::env::temp_dir().join(format!("atelier-pair-c-{}.plist", std::process::id()));

    let runner = std::thread::spawn(move || {
        let callbacks = AtelierPairCallbacks {
            ctx: ctx as *mut c_void,
            advertise: Some(record_advert),
            show_pin: None,
            log: None,
        };
        let name = CString::new(DISPLAY_NAME).unwrap();
        let path = CString::new(out.to_string_lossy().into_owned()).unwrap();
        let mut message = null_mut();
        let code = unsafe {
            atelier_pair_session_run(
                session as *const AtelierPairSession,
                name.as_ptr(),
                path.as_ptr(),
                0,
                callbacks,
                &mut message,
            )
        };
        let text = unsafe { CStr::from_ptr(message) }.to_string_lossy().into_owned();
        unsafe { atelier_pair_string_free(message) };
        (code, text)
    });

    let (instance, port, txt_len) = rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(instance.len(), 36);
    assert_ne!(port, 0);
    assert!(txt_len > 0);

    unsafe { atelier_pair_session_cancel(session as *const AtelierPairSession) };
    let (code, text) = runner.join().unwrap();
    assert_eq!((code, text.as_str()), (ATELIER_PAIR_CANCELLED, "cancelled"));
    unsafe {
        atelier_pair_session_free(session as *mut AtelierPairSession);
        drop(Box::from_raw(ctx as *mut mpsc::Sender<(String, u16, usize)>));
    }
}

#[test]
fn c_api_rejects_null_arguments() {
    let callbacks = AtelierPairCallbacks {
        ctx: null_mut(),
        advertise: None,
        show_pin: None,
        log: None,
    };
    let mut message = null_mut();
    let code = unsafe { atelier_pair_session_run(null(), null(), null(), 0, callbacks, &mut message) };
    assert_eq!(code, ATELIER_PAIR_FAILED);
    assert_eq!(unsafe { CStr::from_ptr(message) }.to_str(), Ok("no session"));
    unsafe {
        atelier_pair_string_free(message);
        atelier_pair_string_free(null_mut());
        atelier_pair_session_cancel(null());
        atelier_pair_session_free(null_mut());
    }
}
