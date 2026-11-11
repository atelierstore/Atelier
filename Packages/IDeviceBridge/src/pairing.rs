//! Atelier's on-phone pairing host, for iOS 27's device-initiated pairing (#9).
//!
//! On iOS 27 the phone itself can start a pairing. A host on the local network
//! advertises `_remotepairing-pairable-host._tcp`; the user picks it under
//! Settings › Privacy & Security › Developer Mode and types the 6-digit code the
//! host shows; the phone then runs pair-setup against the host. The result is an
//! RPPairing file, the kind route A installs with, made with no computer.
//!
//! The protocol is idevice's (MIT): [`PairableHost`] is the responder side. This
//! module adapts it to an iOS app, and differs from idevice's own C entry point
//! (`pairable_host_accept` in idevice's `ffi/src/pairable_host.rs`) in four ways:
//!
//! - It doesn't advertise the service. idevice uses `mdns-sd`, which sends raw
//!   multicast, and an iOS app can't do that without Apple's multicast
//!   entitlement. The app advertises through Bonjour instead, so this hands it
//!   the instance name, the port and a ready-made TXT record.
//! - Each attempt gets a fresh identity. idevice derives the identifier from the
//!   host name, which would be the same on every attempt here; a fresh one means
//!   the phone sees a retry as a new host, not one it may already hold a record for.
//! - It can be cancelled and has a deadline, so an attempt nobody finishes never
//!   leaves the app waiting.
//! - A connection that ends before the code is shown doesn't end the attempt.
//!
//! This is the install spike's host (spike/InstallSpike/IDeviceBridge), which
//! paired an iPhone on iOS 27.0.1 (docs/install-routes.md, third round), without
//! the spike's reconnect experiments. StikPair does the same on-phone pairing,
//! but its licence forbids commercial use, so none of its code is used here.
use std::cell::Cell;
use std::ffi::{CStr, CString, c_char, c_void};
use std::hash::{BuildHasher, Hasher};
use std::net::Ipv4Addr;
use std::path::{Path, PathBuf};
use std::ptr::null_mut;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use idevice::remote_pairing::{PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket};
use tokio::net::TcpListener;
use tokio::sync::Notify;

/// The model the host reports. iOS treats a pairable host as a computer, and
/// this Mac identifier is idevice's own default.
const HOST_MODEL: &str = "Mac17,7";

/// What the app needs to advertise the host through Bonjour.
#[derive(Debug, Clone)]
pub struct Advert {
    /// The Bonjour instance name: the host's pairing identifier, as idevice uses it.
    pub instance: String,
    pub port: u16,
    /// The TXT record in DNS wire format, ready for `NetService.setTXTRecord`.
    pub txt_record: Vec<u8>,
}

/// The phone that paired.
#[derive(Debug, Clone)]
pub struct Paired {
    pub device_name: String,
    pub device_model: String,
}

#[derive(Debug)]
pub enum PairError {
    Cancelled,
    TimedOut,
    Failed(String),
}

impl std::fmt::Display for PairError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PairError::Cancelled => f.write_str("cancelled"),
            PairError::TimedOut => f.write_str("timed out"),
            PairError::Failed(reason) => f.write_str(reason),
        }
    }
}

fn failed(reason: String) -> PairError {
    PairError::Failed(reason)
}

/// Lets another thread stop a running [`host_once`].
#[derive(Default)]
pub struct Cancel {
    requested: AtomicBool,
    wake: Notify,
}

impl Cancel {
    pub fn cancel(&self) {
        self.requested.store(true, Ordering::SeqCst);
        self.wake.notify_waiters();
    }

    pub fn is_cancelled(&self) -> bool {
        self.requested.load(Ordering::SeqCst)
    }

    /// Resolves once [`Self::cancel`] has been called, also if that happened first.
    async fn requested(&self) {
        loop {
            let mut notified = std::pin::pin!(self.wake.notified());
            // Register as a waiter before checking, so a cancel in between isn't missed.
            notified.as_mut().enable();
            if self.is_cancelled() {
                return;
            }
            notified.await;
        }
    }
}

/// Runs one pairing attempt: listens, hands the service details to `advertise`,
/// and waits for a phone to pair. `show_pin` gets the code to display, once for
/// each phone that starts pair-setup. On success the pairing file replaces
/// whatever is at `out_path`; on any failure nothing is written.
///
/// Ends with [`PairError::Cancelled`] when `cancel` fires, and with
/// [`PairError::TimedOut`] once `deadline` (if any) has passed.
pub async fn host_once(
    display_name: &str,
    out_path: &Path,
    cancel: &Cancel,
    deadline: Option<Duration>,
    log: &dyn Fn(&str),
    advertise: impl FnOnce(&Advert),
    show_pin: impl Fn(&str),
) -> Result<Paired, PairError> {
    let attempt = async {
        let listener = TcpListener::bind((Ipv4Addr::UNSPECIFIED, 0))
            .await
            .map_err(|e| failed(format!("couldn't listen: {e}")))?;
        let port = listener
            .local_addr()
            .map_err(|e| failed(format!("couldn't read the port: {e}")))?
            .port();

        let mut identity = RpPairingFile::generate(&unique_seed(display_name));
        let host_info = PairableHostInfo::generate(display_name, HOST_MODEL);
        let advert = Advert {
            instance: identity.identifier.clone(),
            port,
            txt_record: txt_record(&host_info.mdns_txt_records(&identity.identifier))?,
        };
        log(&format!("listening on port {port} as {}", advert.instance));
        advertise(&advert);

        accept_pairing(&listener, &host_info, &mut identity, out_path, log, &show_pin).await
    };

    let timer = async {
        match deadline {
            Some(after) => tokio::time::sleep(after).await,
            None => std::future::pending::<()>().await,
        }
    };

    tokio::select! {
        biased;
        _ = cancel.requested() => Err(PairError::Cancelled),
        _ = timer => Err(PairError::TimedOut),
        result = attempt => result,
    }
}

/// Accepts connections on `listener` until one completes pair-setup, then saves
/// the pairing file to `out_path` and returns the paired phone. A connection
/// that drops before pair-setup starts is logged and the loop goes on.
async fn accept_pairing(
    listener: &TcpListener,
    host_info: &PairableHostInfo,
    identity: &mut RpPairingFile,
    out_path: &Path,
    log: &dyn Fn(&str),
    show_pin: &dyn Fn(&str),
) -> Result<Paired, PairError> {
    loop {
        let (stream, peer) = listener
            .accept()
            .await
            .map_err(|e| failed(format!("couldn't accept a connection: {e}")))?;
        log(&format!("connection from {peer}"));
        let _ = stream.set_nodelay(true);

        let code_shown = Cell::new(false);
        let mut host = PairableHost::new(RpPairingSocket::new_device(stream), host_info.clone());
        let outcome = host
            .accept(identity, |pin| {
                code_shown.set(true);
                show_pin(&pin);
                async {}
            })
            .await;

        match outcome {
            Ok(device) => {
                write_replacing(out_path, &identity.to_bytes()).map_err(|e| {
                    failed(format!("paired, but couldn't save the pairing file: {e}"))
                })?;
                log(&format!(
                    "paired with {} ({}); pairing file saved",
                    device.name, device.model
                ));
                return Ok(Paired {
                    device_name: device.name,
                    device_model: device.model,
                });
            }
            Err(e) if !code_shown.get() => {
                log(&format!(
                    "connection from {peer} ended before pair-setup started ({e}); still listening"
                ));
            }
            Err(e) => return Err(failed(format!("pairing failed: {e}"))),
        }
    }
}

/// A seed for idevice's name-based identifier that differs on every attempt.
fn unique_seed(display_name: &str) -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    // RandomState's keys come from the OS's random source.
    let random = std::collections::hash_map::RandomState::new()
        .build_hasher()
        .finish();
    format!("{display_name}/{nanos}/{random:016x}")
}

/// Encodes TXT key/value pairs in DNS wire format: per entry, one length byte
/// followed by `key=value`.
pub(crate) fn txt_record(pairs: &[(String, String)]) -> Result<Vec<u8>, PairError> {
    let mut record = Vec::new();
    for (key, value) in pairs {
        let entry = format!("{key}={value}");
        let len = u8::try_from(entry.len())
            .map_err(|_| failed(format!("TXT entry `{key}` is longer than 255 bytes")))?;
        record.push(len);
        record.extend_from_slice(entry.as_bytes());
    }
    Ok(record)
}

/// Where [`write_replacing`] stages the file before moving it into place.
pub(crate) fn partial_path(path: &Path) -> PathBuf {
    let mut partial = path.as_os_str().to_owned();
    partial.push(".partial");
    PathBuf::from(partial)
}

/// Writes next to `path`, then renames over it, so a failed write never leaves
/// half a pairing file behind.
fn write_replacing(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let partial = partial_path(path);
    std::fs::write(&partial, bytes)?;
    std::fs::rename(&partial, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&partial);
    })
}

// MARK: C API

/// A pairing attempt that another thread can cancel. Create it with
/// [`atelier_pair_session_new`], run it once with [`atelier_pair_session_run`],
/// and free it with [`atelier_pair_session_free`] after the run has returned.
pub struct AtelierPairSession {
    cancel: Cancel,
}

/// Callbacks for [`atelier_pair_session_run`], all called on the thread running
/// it. Pointer arguments are only valid during the call. Any of them may be NULL.
#[repr(C)]
pub struct AtelierPairCallbacks {
    /// Passed back to every callback.
    pub ctx: *mut c_void,
    /// The host is listening: advertise `_remotepairing-pairable-host._tcp` with
    /// this instance name, port and TXT record (DNS wire format).
    pub advertise: Option<
        extern "C" fn(
            ctx: *mut c_void,
            instance: *const c_char,
            port: u16,
            txt_record: *const u8,
            txt_len: usize,
        ),
    >,
    /// Show this 6-digit code; the user types it on the phone.
    pub show_pin: Option<extern "C" fn(ctx: *mut c_void, pin: *const c_char)>,
    /// A progress line for the app's log. Never contains keys or the code.
    pub log: Option<extern "C" fn(ctx: *mut c_void, line: *const c_char)>,
}

impl AtelierPairCallbacks {
    fn send_log(&self, line: &str) {
        if let (Some(cb), Ok(line)) = (self.log, CString::new(line)) {
            cb(self.ctx, line.as_ptr());
        }
    }

    fn send_advert(&self, advert: &Advert) {
        if let (Some(cb), Ok(instance)) = (self.advertise, CString::new(advert.instance.as_str())) {
            cb(
                self.ctx,
                instance.as_ptr(),
                advert.port,
                advert.txt_record.as_ptr(),
                advert.txt_record.len(),
            );
        }
    }

    fn send_pin(&self, pin: &str) {
        if let (Some(cb), Ok(pin)) = (self.show_pin, CString::new(pin)) {
            cb(self.ctx, pin.as_ptr());
        }
    }
}

/// [`atelier_pair_session_run`] results.
pub const ATELIER_PAIR_PAIRED: i32 = 0;
pub const ATELIER_PAIR_FAILED: i32 = 1;
pub const ATELIER_PAIR_CANCELLED: i32 = 2;
pub const ATELIER_PAIR_TIMED_OUT: i32 = 3;

/// Creates a session. Never returns NULL.
#[unsafe(no_mangle)]
pub extern "C" fn atelier_pair_session_new() -> *mut AtelierPairSession {
    Box::into_raw(Box::new(AtelierPairSession {
        cancel: Cancel::default(),
    }))
}

/// Asks the session's run to stop; it then returns `ATELIER_PAIR_CANCELLED`.
/// Safe from any thread, before or during the run, and more than once.
///
/// # Safety
/// `session` must be NULL or a session from [`atelier_pair_session_new`] that
/// hasn't been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_pair_session_cancel(session: *const AtelierPairSession) {
    if let Some(session) = unsafe { session.as_ref() } {
        session.cancel.cancel();
    }
}

/// Frees a session.
///
/// # Safety
/// `session` must be NULL or a session from [`atelier_pair_session_new`] whose
/// run, if any, has returned. It must not be used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_pair_session_free(session: *mut AtelierPairSession) {
    if !session.is_null() {
        drop(unsafe { Box::from_raw(session) });
    }
}

/// Runs one pairing attempt and blocks until it ends, so call it off the main
/// thread.
///
/// `display_name` is what the phone lists ("Pair with …"). On success the pairing
/// file replaces whatever is at `out_path`. `timeout_secs` 0 means no deadline.
/// Returns one of the `ATELIER_PAIR_*` codes. If `out_message` isn't NULL it
/// receives the paired phone as "name (model)", or why the attempt ended; free it
/// with [`atelier_pair_string_free`].
///
/// # Safety
/// `session` must be a live session. `display_name` and `out_path` must be NULL
/// or valid NUL-terminated strings. `out_message` must be NULL or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_pair_session_run(
    session: *const AtelierPairSession,
    display_name: *const c_char,
    out_path: *const c_char,
    timeout_secs: u32,
    callbacks: AtelierPairCallbacks,
    out_message: *mut *mut c_char,
) -> i32 {
    let result = unsafe { run_session(session, display_name, out_path, timeout_secs, &callbacks) };
    let (code, message) = match result {
        Ok(paired) => (
            ATELIER_PAIR_PAIRED,
            format!("{} ({})", paired.device_name, paired.device_model),
        ),
        Err(PairError::Cancelled) => (ATELIER_PAIR_CANCELLED, "cancelled".to_string()),
        Err(PairError::TimedOut) => (ATELIER_PAIR_TIMED_OUT, "timed out".to_string()),
        Err(PairError::Failed(reason)) => (ATELIER_PAIR_FAILED, reason),
    };
    if !out_message.is_null() {
        unsafe { *out_message = c_string(&message) };
    }
    code
}

unsafe fn run_session(
    session: *const AtelierPairSession,
    display_name: *const c_char,
    out_path: *const c_char,
    timeout_secs: u32,
    callbacks: &AtelierPairCallbacks,
) -> Result<Paired, PairError> {
    let session = unsafe { session.as_ref() }.ok_or_else(|| failed("no session".into()))?;
    let display_name = unsafe { utf8(display_name, "display_name") }?;
    let out_path = unsafe { utf8(out_path, "out_path") }?;
    new_runtime()?.block_on(host_once(
        display_name,
        Path::new(out_path),
        &session.cancel,
        deadline(timeout_secs),
        &|line| callbacks.send_log(line),
        |advert| callbacks.send_advert(advert),
        |pin| callbacks.send_pin(pin),
    ))
}

/// A current-thread runtime runs the whole attempt on the calling thread, which
/// is why the callbacks are only ever called from it.
fn new_runtime() -> Result<tokio::runtime::Runtime, PairError> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| failed(format!("couldn't start the async runtime: {e}")))
}

/// `timeout_secs` 0 means no deadline.
fn deadline(timeout_secs: u32) -> Option<Duration> {
    (timeout_secs > 0).then(|| Duration::from_secs(timeout_secs.into()))
}

unsafe fn utf8<'a>(p: *const c_char, what: &str) -> Result<&'a str, PairError> {
    if p.is_null() {
        return Err(failed(format!("{what} is NULL")));
    }
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .map_err(|_| failed(format!("{what} is not UTF-8")))
}

fn c_string(s: &str) -> *mut c_char {
    CString::new(s.replace('\0', "")).map_or(null_mut(), CString::into_raw)
}

/// Frees a string from [`atelier_pair_session_run`].
///
/// # Safety
/// `s` must be NULL or a string this library returned, freed only once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_pair_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}
