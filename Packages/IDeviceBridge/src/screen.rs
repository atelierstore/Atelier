//! Atelier's look at the Home Screen, for Open Spaces' Find Open Spaces
//! Automatically (11 Nov 2026). iOS doesn't report the open spaces between
//! icons, so Atelier goes to a page on the Home Screen, takes a screenshot of
//! it and comes back, and the app marks the places it saw empty. Each step is
//! a developer service of Apple's developer disk image, as Xcode uses them:
//! pressing Home and swiping through CoreDevice's HID services, the
//! screenshot through its screen capture service, and opening Atelier again
//! through its app service. The image is mounted for this iPhone first: the
//! personalized one through the image mounter up to iOS 26.3, the cryptex one
//! through cryptexd from iOS 26.4, as StikDebug does. Apple's signing server
//! personalizes either for this iPhone.
//!
//! iOS drops synthetic HID events unless a screen stream is running (idevice's
//! `core_device::hid`), so a session starts one, as Xcode's Device Hub does,
//! and throws its video away, as idevice's own `hid` tool does.
//!
//! Only builds inside idevice-ffi, which `build-rust.sh` adds it to, because it
//! takes idevice-ffi's handles.

use std::ffi::{CStr, CString, c_char};
use std::future::Future;
use std::ptr::null_mut;
use std::time::Duration;

use idevice::core_device::{
    AppServiceClient, ButtonState, CallInfoBlob, DisplayServiceClient, ImageFormat,
    IndigoHidClient, ScreenCaptureServiceClient, TOUCHSCREEN_STATE_CONTACT,
    TOUCHSCREEN_STATE_RELEASE, UniversalHidServiceClient, build_screen_audio_offer,
    build_screen_video_offer, build_start_audio_parameters, build_start_video_parameters,
};
use idevice::cryptexd::Cryptex1Assets;
use idevice::lockdown::LockdownClient;
use idevice::mobile_image_mounter::ImageMounter;
use idevice::rsd::RsdHandshake;
use idevice::tcp::handle::{AdapterHandle as Adapter, UdpSocketHandle};
use idevice::{IdeviceError, ReadWrite, RsdService};

use crate::core_device_proxy::AdapterHandle;
use crate::rsd::RsdHandshakeHandle;
use crate::{IdeviceFfiError, ffi_err, run_sync_local};

/// The developer services a look at the Home Screen uses, which iOS lists
/// once the developer disk image is mounted.
const SERVICES: [&str; 5] = [
    "com.apple.coredevice.displayservice",
    "com.apple.coredevice.hid.indigo",
    "com.apple.coredevice.hid.universalhidservice",
    "com.apple.coredevice.screencaptureservice",
    "com.apple.coredevice.appservice",
];

/// The longest a mount may take: Apple's signing server, the upload of the
/// image (about 20 MB) and the mount itself.
const MOUNT_WAIT: Duration = Duration::from_secs(120);
/// The longest starting the screen stream and the services may take.
const START_WAIT: Duration = Duration::from_secs(20);
/// The longest a press, a swipe, a screenshot or a launch may take.
const STEP_WAIT: Duration = Duration::from_secs(15);
/// How long iOS gets to match its HID services to the new stream before
/// events count, as idevice's `hid` tool waits.
const STREAM_SETTLE: Duration = Duration::from_millis(400);

/// What Atelier tells the screen stream it is: what Xcode's Device Hub sends,
/// which iOS accepted in idevice's tests.
const CLIENT_SUPPORTED_FEATURES: u64 = 140;
const MAIN_DISPLAY: i64 = 1;

/// The Home button: HID's consumer page, its Menu usage, held as long as a
/// press, as idevice's `hid` tool presses it.
const CONSUMER_PAGE: u64 = 0x0C;
const HOME_USAGE: u64 = 0x40;
const HOME_HOLD: Duration = Duration::from_millis(80);

/// A swipe's touch samples and the time between them: about a third of a
/// second, which the Home Screen takes as a swipe rather than a tap.
const SWIPE_STEPS: u32 = 20;
const SWIPE_STEP_MS: u64 = 16;
/// A slide's touch samples come this far apart, a screen refresh, also while
/// the finger rests, so iOS sees a touch held rather than one let go.
const SLIDE_STEP_MS: u64 = 16;

/// The developer services iOS doesn't list in this tunnel's handshake, one
/// per line, or an empty string when they're all there: all of them before
/// the developer disk image is mounted. A handshake from before a mount
/// doesn't list what it brings, so check on a new tunnel after one. Free the
/// string with [`atelier_screen_string_free`].
///
/// # Safety
/// `handshake` must be a live handshake and `out_missing` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_developer_services_missing(
    handshake: *mut RsdHandshakeHandle,
    out_missing: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    if handshake.is_null() || out_missing.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let services = &unsafe { &(*handshake).0 }.services;
    let missing: Vec<&str> = SERVICES
        .into_iter()
        .filter(|name| !services.contains_key(*name))
        .collect();
    unsafe { *out_missing = c_string(&missing.join("\n")) };
    null_mut()
}

/// Mounts Apple's personalized developer disk image, for iOS 17 to 26.3:
/// the image, its trust cache and its build manifest, as downloaded. Apple's
/// signing server personalizes it for this iPhone, unless iOS has its ticket
/// already.
///
/// # Safety
/// `adapter` and `handshake` must be live handles from the same tunnel, and
/// each buffer readable for its length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_mount_personalized_image(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    image: *const u8,
    image_length: libc::size_t,
    trust_cache: *const u8,
    trust_cache_length: libc::size_t,
    build_manifest: *const u8,
    build_manifest_length: libc::size_t,
) -> *mut IdeviceFfiError {
    if adapter.is_null()
        || handshake.is_null()
        || image.is_null()
        || trust_cache.is_null()
        || build_manifest.is_null()
    {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let image = unsafe { bytes(image, image_length) }.to_vec();
    let trust_cache = unsafe { bytes(trust_cache, trust_cache_length) }.to_vec();
    let build_manifest = unsafe { bytes(build_manifest, build_manifest_length) }.to_vec();
    let result = run_sync_local(async move {
        let adapter = unsafe { &mut (*adapter).0 };
        let handshake = unsafe { &mut (*handshake).0 };
        within(MOUNT_WAIT, "mounting the developer disk image", async {
            // The mounter first, then lockdownd: idevice's image mounter says
            // iOS stops answering when lockdownd isn't asked after it.
            let mut mounter = ImageMounter::connect_rsd(adapter, handshake).await?;
            let chip = unique_chip_id(adapter, handshake).await?;
            mounter
                .mount_personalized_rsd(
                    adapter,
                    handshake,
                    image,
                    trust_cache,
                    &build_manifest,
                    None,
                    chip,
                )
                .await
        })
        .await
    });
    match result {
        Ok(()) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// Installs Apple's developer disk image as a cryptex, for iOS 26.4 and
/// later: the image, its trust cache, its cryptex info, its root hash and its
/// build manifest, as downloaded. Apple's signing server personalizes it for
/// this iPhone.
///
/// # Safety
/// `adapter` and `handshake` must be live handles from the same tunnel, and
/// each buffer readable for its length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_install_image_cryptex(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    image: *const u8,
    image_length: libc::size_t,
    trust_cache: *const u8,
    trust_cache_length: libc::size_t,
    info: *const u8,
    info_length: libc::size_t,
    root_hash: *const u8,
    root_hash_length: libc::size_t,
    build_manifest: *const u8,
    build_manifest_length: libc::size_t,
) -> *mut IdeviceFfiError {
    if adapter.is_null()
        || handshake.is_null()
        || image.is_null()
        || trust_cache.is_null()
        || info.is_null()
        || root_hash.is_null()
        || build_manifest.is_null()
    {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let manifest: plist::Dictionary =
        match plist::from_bytes(unsafe { bytes(build_manifest, build_manifest_length) }) {
            Ok(manifest) => manifest,
            Err(e) => {
                return ffi_err!(IdeviceError::UnexpectedResponse(format!(
                    "couldn't read the build manifest: {e}"
                )));
            }
        };
    let identity = match idevice::tss::select_cryptex_build_identity(&manifest) {
        Ok(identity) => identity.clone(),
        Err(e) => return ffi_err!(e),
    };
    let assets = Cryptex1Assets::from_parts(
        unsafe { bytes(image, image_length) }.to_vec(),
        unsafe { bytes(trust_cache, trust_cache_length) }.to_vec(),
        unsafe { bytes(info, info_length) }.to_vec(),
        unsafe { bytes(root_hash, root_hash_length) }.to_vec(),
        identity,
    );
    let result = run_sync_local(async move {
        let adapter = unsafe { &mut (*adapter).0 };
        let handshake = unsafe { &mut (*handshake).0 };
        within(
            MOUNT_WAIT,
            "installing the developer disk image",
            idevice::cryptexd::install_ddi(adapter, handshake, &assets),
        )
        .await
    });
    match result {
        Ok(_) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// A look at the Home Screen in progress: the screen stream that has iOS take
/// Atelier's HID events, and the services that press, swipe and take the
/// screenshot. End it with [`atelier_screen_session_end`].
pub struct AtelierScreenSession {
    display: DisplayServiceClient<Box<dyn ReadWrite>>,
    buttons: IndigoHidClient<Box<dyn ReadWrite>>,
    touches: UniversalHidServiceClient<Box<dyn ReadWrite>>,
    capture: ScreenCaptureServiceClient<Box<dyn ReadWrite>>,
    /// Read the stream's audio and video and throw them away, as jktcp keeps
    /// every datagram nobody reads.
    drains: Vec<tokio::task::JoinHandle<()>>,
}

/// Starts the screen stream and connects the services a look at the Home
/// Screen uses. Needs the developer disk image mounted. The tunnel must
/// outlive the session.
///
/// # Safety
/// `adapter` and `handshake` must be live handles from the same tunnel, and
/// `out_session` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_screen_session_start(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    out_session: *mut *mut AtelierScreenSession,
) -> *mut IdeviceFfiError {
    if adapter.is_null() || handshake.is_null() || out_session.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let result = run_sync_local(async move {
        let adapter = unsafe { &mut (*adapter).0 };
        let handshake = unsafe { &mut (*handshake).0 };
        within(START_WAIT, "starting the screen stream", start(adapter, handshake)).await
    });
    match result {
        Ok(session) => {
            unsafe { *out_session = Box::into_raw(Box::new(session)) };
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

async fn start(
    adapter: &mut Adapter,
    handshake: &mut RsdHandshake,
) -> Result<AtelierScreenSession, IdeviceError> {
    let mut display = DisplayServiceClient::connect_rsd(adapter, handshake).await?;
    let audio = adapter.bind_udp(0).await?;
    let video = adapter.bind_udp(0).await?;
    let receiver = adapter.host_ip().to_string();
    let sender = adapter.peer_ip().to_string();
    let call_info = CallInfoBlob {
        call_id: 0,
        client_version: 1,
        device_type: "Mac17,7".into(),
        framework_version: "2205.3.1".into(),
        os_version: "25F71".into(),
        device_name: None,
        audio_device_uid: None,
    };
    // Audio first, which sets up the screen sharing session the video joins,
    // as Device Hub does.
    let session_id = uuid::Uuid::new_v4();
    let audio_call = uuid::Uuid::new_v4().to_string().to_uppercase();
    let offer = build_screen_audio_offer(&audio_call, &call_info)?;
    display
        .start_media_stream(build_start_audio_parameters(
            &receiver,
            audio.local_port(),
            &sender,
            50000,
            offer,
            CLIENT_SUPPORTED_FEATURES,
            session_id,
        ))
        .await?;
    let video =
        video_after_start(&mut display, video, &receiver, &sender, &call_info, session_id).await?;
    let drains = vec![drain(audio), drain(video)];
    let services = async {
        tokio::time::sleep(STREAM_SETTLE).await;
        let buttons = IndigoHidClient::connect_rsd(adapter, handshake).await?;
        let touches = UniversalHidServiceClient::connect_rsd(adapter, handshake).await?;
        let capture = ScreenCaptureServiceClient::connect_rsd(adapter, handshake).await?;
        Ok::<_, IdeviceError>((buttons, touches, capture))
    }
    .await;
    match services {
        Ok((buttons, touches, capture)) => Ok(AtelierScreenSession {
            display,
            buttons,
            touches,
            capture,
            drains,
        }),
        Err(e) => {
            stop(&mut display, &drains).await;
            Err(e)
        }
    }
}

/// Starts the stream's video, on the audio's session, and hands back its
/// socket to drain.
async fn video_after_start(
    display: &mut DisplayServiceClient<Box<dyn ReadWrite>>,
    video: UdpSocketHandle,
    receiver: &str,
    sender: &str,
    call_info: &CallInfoBlob,
    session_id: uuid::Uuid,
) -> Result<UdpSocketHandle, IdeviceError> {
    let call = uuid::Uuid::new_v4().to_string().to_uppercase();
    // The SSRC only has to match RTCP Atelier would send, and it sends none.
    let ssrc = uuid::Uuid::new_v4().as_u128() as u32;
    let offer = build_screen_video_offer(&call, call_info, ssrc)?;
    let started = display
        .start_media_stream(build_start_video_parameters(
            receiver,
            video.local_port(),
            sender,
            50001,
            offer,
            CLIENT_SUPPORTED_FEATURES,
            MAIN_DISPLAY,
            session_id,
        ))
        .await;
    if let Err(e) = started {
        // The audio is running; stop it before giving up.
        let _ = tokio::time::timeout(STEP_WAIT, display.stop_media_stream()).await;
        return Err(e);
    }
    Ok(video)
}

/// Reads `socket` until the session ends, throwing what comes away.
fn drain(socket: UdpSocketHandle) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move { while socket.recv().await.is_ok() {} })
}

/// Stops the screen stream and its drains, as far as iOS answers.
async fn stop(
    display: &mut DisplayServiceClient<Box<dyn ReadWrite>>,
    drains: &[tokio::task::JoinHandle<()>],
) {
    let _ = tokio::time::timeout(STEP_WAIT, display.stop_media_stream()).await;
    for drain in drains {
        drain.abort();
    }
}

/// Presses Home, as the button does.
///
/// # Safety
/// `session` must be a live session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_screen_press_home(
    session: *mut AtelierScreenSession,
) -> *mut IdeviceFfiError {
    if session.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let session = unsafe { &mut *session };
    let result = run_sync_local(within(STEP_WAIT, "pressing Home", async {
        session
            .buttons
            .send_button(CONSUMER_PAGE, HOME_USAGE, ButtonState::Down)
            .await?;
        tokio::time::sleep(HOME_HOLD).await;
        session
            .buttons
            .send_button(CONSUMER_PAGE, HOME_USAGE, ButtonState::Up)
            .await
    }));
    match result {
        Ok(()) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// Swipes across the screen at height `y`, from `from_x` to `to_x`, each a
/// fraction of the screen from its top left, 0 to 1: from right to left
/// goes to the Home Screen's next page.
///
/// # Safety
/// `session` must be a live session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_screen_swipe(
    session: *mut AtelierScreenSession,
    from_x: f64,
    to_x: f64,
    y: f64,
) -> *mut IdeviceFfiError {
    if session.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let session = unsafe { &mut *session };
    let (from_x, to_x, y) = (touch_point(from_x), touch_point(to_x), touch_point(y));
    let result = run_sync_local(within(
        STEP_WAIT,
        "swiping",
        session
            .touches
            .drag(from_x, y, to_x, y, SWIPE_STEPS, SWIPE_STEP_MS),
    ));
    match result {
        Ok(()) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// Slides a finger along the screen at height `y`, from `from_x` to `to_x`,
/// each a fraction of the screen from its top left, 0 to 1: it rests at the
/// start for `hold_ms`, moves for `move_ms` and rests at the end for
/// `settle_ms` before it lifts. On the Home Screen's page dots, sliding
/// goes through the pages, as a finger does (12 Nov 2026).
///
/// # Safety
/// `session` must be a live session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_screen_slide(
    session: *mut AtelierScreenSession,
    from_x: f64,
    to_x: f64,
    y: f64,
    hold_ms: u64,
    move_ms: u64,
    settle_ms: u64,
) -> *mut IdeviceFfiError {
    if session.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let session = unsafe { &mut *session };
    let (from_x, to_x, y) = (touch_point(from_x), touch_point(to_x), touch_point(y));
    let wait = STEP_WAIT + Duration::from_millis(hold_ms + move_ms + settle_ms);
    let result = run_sync_local(within(wait, "sliding", async {
        let touches = &mut session.touches;
        for _ in 0..(hold_ms / SLIDE_STEP_MS).max(1) {
            touches
                .send_touchscreen(TOUCHSCREEN_STATE_CONTACT, from_x, y, None)
                .await?;
            tokio::time::sleep(Duration::from_millis(SLIDE_STEP_MS)).await;
        }
        let steps = (move_ms / SLIDE_STEP_MS).max(1);
        for step in 1..=steps {
            let t = step as f64 / steps as f64;
            let x = (f64::from(from_x) + (f64::from(to_x) - f64::from(from_x)) * t).round() as u16;
            touches
                .send_touchscreen(TOUCHSCREEN_STATE_CONTACT, x, y, None)
                .await?;
            tokio::time::sleep(Duration::from_millis(SLIDE_STEP_MS)).await;
        }
        for _ in 0..(settle_ms / SLIDE_STEP_MS) {
            touches
                .send_touchscreen(TOUCHSCREEN_STATE_CONTACT, to_x, y, None)
                .await?;
            tokio::time::sleep(Duration::from_millis(SLIDE_STEP_MS)).await;
        }
        touches
            .send_touchscreen(TOUCHSCREEN_STATE_RELEASE, to_x, y, None)
            .await
    }));
    match result {
        Ok(()) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// A screenshot of the screen as it is, as PNG data. Free the bytes with
/// [`atelier_screen_data_free`].
///
/// # Safety
/// `session` must be a live session, and `out_png` and `out_length`
/// writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_screen_screenshot(
    session: *mut AtelierScreenSession,
    out_png: *mut *mut u8,
    out_length: *mut libc::size_t,
) -> *mut IdeviceFfiError {
    if session.is_null() || out_png.is_null() || out_length.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let session = unsafe { &mut *session };
    let result = run_sync_local(within(
        STEP_WAIT,
        "taking a screenshot",
        session.capture.take_screenshot(None, ImageFormat::Png),
    ));
    match result {
        Ok(png) => {
            let png = png.into_boxed_slice();
            unsafe {
                *out_length = png.len();
                *out_png = Box::into_raw(png).cast::<u8>();
            }
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Stops the screen stream, as far as iOS answers, and frees the session.
///
/// # Safety
/// `session` must be NULL or a live session, ended only once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_screen_session_end(session: *mut AtelierScreenSession) {
    if session.is_null() {
        return;
    }
    let mut session = unsafe { Box::from_raw(session) };
    run_sync_local(async {
        stop(&mut session.display, &session.drains).await;
    });
}

/// Opens the app installed as `bundle_id`, as Xcode does after a run: brings
/// it to the front if it's running, such as Atelier itself in the background.
///
/// # Safety
/// `adapter` and `handshake` must be live handles from the same tunnel, and
/// `bundle_id` a valid NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_launch_app(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    bundle_id: *const c_char,
) -> *mut IdeviceFfiError {
    if adapter.is_null() || handshake.is_null() || bundle_id.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let Ok(bundle_id) = unsafe { CStr::from_ptr(bundle_id) }.to_str().map(str::to_owned) else {
        return ffi_err!(IdeviceError::FfiInvalidString);
    };
    let result = run_sync_local(async move {
        let adapter = unsafe { &mut (*adapter).0 };
        let handshake = unsafe { &mut (*handshake).0 };
        within(STEP_WAIT, "opening the app", async {
            let mut apps = AppServiceClient::connect_rsd(adapter, handshake).await?;
            apps.launch_application(bundle_id, &[], false, false, None, None, None)
                .await
                .map(|_| ())
        })
        .await
    });
    match result {
        Ok(()) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// This iPhone's unique chip ID, which Apple's signing server personalizes
/// the developer disk image for, from lockdownd over the tunnel.
async fn unique_chip_id(adapter: &mut Adapter, handshake: &mut RsdHandshake) -> Result<u64, IdeviceError> {
    let mut lockdown = LockdownClient::connect_rsd(adapter, handshake).await?;
    let value = lockdown.get_value(Some("UniqueChipID"), None).await?;
    value
        .as_unsigned_integer()
        .ok_or_else(|| IdeviceError::UnexpectedResponse("UniqueChipID isn't a number".into()))
}

/// Runs `work`, or fails saying what didn't answer after `wait`: the tunnel's
/// calls have no time limit of their own.
async fn within<T>(
    wait: Duration,
    what: &str,
    work: impl Future<Output = Result<T, IdeviceError>>,
) -> Result<T, IdeviceError> {
    match tokio::time::timeout(wait, work).await {
        Ok(result) => result,
        Err(_) => Err(IdeviceError::UnexpectedResponse(format!(
            "no answer {what} after {} s",
            wait.as_secs()
        ))),
    }
}

/// A fraction of the screen, 0 to 1, as the touchscreen's coordinates, 0 to
/// 65535.
fn touch_point(fraction: f64) -> u16 {
    (fraction.clamp(0.0, 1.0) * f64::from(u16::MAX)).round() as u16
}

/// # Safety
/// `data` must be readable for `length` bytes.
unsafe fn bytes<'a>(data: *const u8, length: libc::size_t) -> &'a [u8] {
    if length == 0 {
        return &[];
    }
    unsafe { std::slice::from_raw_parts(data, length) }
}

fn c_string(s: &str) -> *mut c_char {
    CString::new(s.replace('\0', "")).map_or(null_mut(), CString::into_raw)
}

/// Frees a string from this module.
///
/// # Safety
/// `s` must be NULL or a string this module returned, freed only once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_screen_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

/// Frees bytes from this module.
///
/// # Safety
/// `data` must be NULL or bytes this module returned, with the length it
/// gave, freed only once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_screen_data_free(data: *mut u8, length: libc::size_t) {
    if !data.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(data, length)) });
    }
}
