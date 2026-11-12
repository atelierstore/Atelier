//! Route A's questions to the phone that idevice's C API answers only with
//! plist handles (#9): this iPhone's UDID, Developer Mode, the installed
//! version of an app, and installd's records of who signed installed apps
//! (#99). And the Home Screen's layout, which SpringBoard reads and writes,
//! to keep an app's spot when Atelier deletes it and installs it again, and
//! iOS's profile service, for the markers in offloaded apps' spots. Each
//! answer comes back as plain text, or as a serialized plist, for Swift, so
//! the app needs none of idevice's plist functions.
//!
//! Only builds inside idevice-ffi, which `build-rust.sh` adds it to, because it
//! takes idevice-ffi's handles. The crate around `pairing.rs` doesn't build it.

use std::ffi::{CStr, CString, c_char};
use std::ptr::null_mut;
use std::time::Duration;

use idevice::lockdown::LockdownClient;
use idevice::springboardservices::SpringBoardServicesClient;
use idevice::{Idevice, IdeviceError, RsdService};

use crate::core_device_proxy::AdapterHandle;
use crate::installation_proxy::InstallationProxyClientHandle;
use crate::rsd::RsdHandshakeHandle;
use crate::{IdeviceFfiError, ffi_err, run_sync_local};

/// The phone's UDID, the one provisioning profiles list. The RSD handshake
/// carries it among the phone's properties; when it doesn't, lockdownd is
/// asked over the tunnel. Free the string with [`atelier_device_string_free`].
///
/// # Safety
/// `adapter` and `handshake` must be live handles from the same tunnel, and
/// `out_udid` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_device_udid(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    out_udid: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    if adapter.is_null() || handshake.is_null() || out_udid.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let from_handshake = unsafe { &(*handshake).0 }
        .properties
        .get("UniqueDeviceID")
        .and_then(|v| v.as_string())
        .map(str::to_owned);
    let udid = match from_handshake {
        Some(udid) => udid,
        None => {
            let result: Result<String, IdeviceError> = run_sync_local(async move {
                let adapter = unsafe { &mut (*adapter).0 };
                let handshake = unsafe { &mut (*handshake).0 };
                let mut lockdown = LockdownClient::connect_rsd(adapter, handshake).await?;
                let value = lockdown.get_value(Some("UniqueDeviceID"), None).await?;
                value.as_string().map(str::to_owned).ok_or_else(|| {
                    IdeviceError::UnexpectedResponse("UniqueDeviceID isn't a string".into())
                })
            });
            match result {
                Ok(udid) => udid,
                Err(e) => return ffi_err!(e),
            }
        }
    };
    unsafe { *out_udid = c_string(&udid) };
    null_mut()
}

/// Whether Developer Mode is on, from lockdownd over the tunnel (the
/// `com.apple.security.mac.amfi` domain's `DeveloperModeStatus`, as
/// pymobiledevice3 reads it). Only for the log while it's unclear whether
/// direct installs need it.
///
/// # Safety
/// `adapter` and `handshake` must be live handles from the same tunnel, and
/// `out_enabled` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_developer_mode(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    out_enabled: *mut bool,
) -> *mut IdeviceFfiError {
    if adapter.is_null() || handshake.is_null() || out_enabled.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let result: Result<bool, IdeviceError> = run_sync_local(async move {
        let adapter = unsafe { &mut (*adapter).0 };
        let handshake = unsafe { &mut (*handshake).0 };
        let mut lockdown = LockdownClient::connect_rsd(adapter, handshake).await?;
        let value = lockdown
            .get_value(Some("DeveloperModeStatus"), Some("com.apple.security.mac.amfi"))
            .await?;
        value.as_boolean().ok_or_else(|| {
            IdeviceError::UnexpectedResponse("DeveloperModeStatus isn't a boolean".into())
        })
    });
    match result {
        Ok(enabled) => {
            unsafe { *out_enabled = enabled };
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// The installed version of `bundle_id` as "short version\tbuild", or NULL
/// when installd doesn't know the app. Free the string with
/// [`atelier_device_string_free`].
///
/// # Safety
/// `client` must be a live installation_proxy client, `bundle_id` a valid
/// NUL-terminated string, and `out_version` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_installed_version(
    client: *mut InstallationProxyClientHandle,
    bundle_id: *const c_char,
    out_version: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    if client.is_null() || bundle_id.is_null() || out_version.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let Ok(bundle_id) = unsafe { CStr::from_ptr(bundle_id) }.to_str().map(str::to_owned) else {
        return ffi_err!(IdeviceError::FfiInvalidString);
    };
    let result = run_sync_local(async {
        let client = unsafe { &mut (*client).0 };
        client.get_apps(None, Some(vec![bundle_id.clone()])).await
    });
    let apps = match result {
        Ok(apps) => apps,
        Err(e) => return ffi_err!(e),
    };
    let version = apps.get(&bundle_id).and_then(|v| v.as_dictionary()).map(|app| {
        let text = |key: &str| app.get(key).and_then(|v| v.as_string()).unwrap_or("");
        format!("{}\t{}", text("CFBundleShortVersionString"), text("CFBundleVersion"))
    });
    unsafe { *out_version = version.map_or(null_mut(), |v| c_string(&v)) };
    null_mut()
}

/// The user's installed apps, one per line as "bundle ID\tshort
/// version\tbuild\tname", for listing them (#17). Free the string with
/// [`atelier_device_string_free`].
///
/// # Safety
/// `client` must be a live installation_proxy client and `out_apps` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_installed_apps(
    client: *mut InstallationProxyClientHandle,
    out_apps: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    if client.is_null() || out_apps.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let result = run_sync_local(async {
        let client = unsafe { &mut (*client).0 };
        client.get_apps(Some("User"), None).await
    });
    let apps = match result {
        Ok(apps) => apps,
        Err(e) => return ffi_err!(e),
    };
    let mut lines: Vec<String> = apps
        .iter()
        .filter_map(|(bundle_id, app)| {
            let app = app.as_dictionary()?;
            let text = |key: &str| {
                app.get(key)
                    .and_then(|v| v.as_string())
                    .unwrap_or("")
                    .replace(['\t', '\n'], " ")
            };
            let name = Some(text("CFBundleDisplayName"))
                .filter(|n| !n.is_empty())
                .unwrap_or_else(|| text("CFBundleName"));
            Some(format!(
                "{bundle_id}\t{}\t{}\t{name}",
                text("CFBundleShortVersionString"),
                text("CFBundleVersion")
            ))
        })
        .collect();
    lines.sort();
    unsafe { *out_apps = c_string(&lines.join("\n")) };
    null_mut()
}

/// installd's whole records of the app installed as `bundle_id`, or of every
/// user app when `bundle_id` is NULL, as a binary plist of bundle ID →
/// record: among other things, who signed each app (`SignerIdentity`) and
/// for which App ID (`Entitlements`), to check an install against the app
/// already on the phone (#99). The dictionary is empty when installd
/// doesn't know the app. Free the bytes with [`atelier_device_data_free`].
///
/// # Safety
/// `client` must be a live installation_proxy client, `bundle_id` NULL or a
/// valid NUL-terminated string, and `out_plist` and `out_length` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_app_records(
    client: *mut InstallationProxyClientHandle,
    bundle_id: *const c_char,
    out_plist: *mut *mut u8,
    out_length: *mut libc::size_t,
) -> *mut IdeviceFfiError {
    if client.is_null() || out_plist.is_null() || out_length.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let bundle_ids = if bundle_id.is_null() {
        None
    } else {
        let Ok(bundle_id) = unsafe { CStr::from_ptr(bundle_id) }.to_str() else {
            return ffi_err!(IdeviceError::FfiInvalidString);
        };
        Some(vec![bundle_id.to_owned()])
    };
    // Any kind of app for one bundle ID, as `atelier_installed_version`
    // asks; the user's apps for all of them, as `atelier_installed_apps`.
    let application_type = if bundle_ids.is_some() { None } else { Some("User") };
    let result = run_sync_local(async {
        let client = unsafe { &mut (*client).0 };
        client.get_apps(application_type, bundle_ids).await
    });
    let apps = match result {
        Ok(apps) => apps,
        Err(e) => return ffi_err!(e),
    };
    let records: plist::Dictionary = apps.into_iter().collect();
    let mut bytes = Vec::new();
    if let Err(e) = plist::Value::Dictionary(records).to_writer_binary(&mut bytes) {
        return ffi_err!(IdeviceError::UnexpectedResponse(format!(
            "couldn't encode installd's records: {e}"
        )));
    }
    let bytes = bytes.into_boxed_slice();
    unsafe {
        *out_length = bytes.len();
        *out_plist = Box::into_raw(bytes).cast::<u8>();
    }
    null_mut()
}

/// The Home Screen's layout, as SpringBoard's getIconState gives it
/// (formatVersion 2), as a binary plist: the Dock, then each page. Free the
/// bytes with [`atelier_device_data_free`].
///
/// # Safety
/// `adapter` and `handshake` must be live handles from the same tunnel, and
/// `out_plist` and `out_length` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_home_screen(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    out_plist: *mut *mut u8,
    out_length: *mut libc::size_t,
) -> *mut IdeviceFfiError {
    if adapter.is_null() || handshake.is_null() || out_plist.is_null() || out_length.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let result = run_sync_local(async move {
        let adapter = unsafe { &mut (*adapter).0 };
        let handshake = unsafe { &mut (*handshake).0 };
        let mut client = SpringBoardServicesClient::connect_rsd(adapter, handshake).await?;
        client.get_icon_state(Some("2")).await
    });
    match result {
        Ok(state) => unsafe { write_plist(&state, out_plist, out_length) },
        Err(e) => ffi_err!(e),
    }
}

/// Has SpringBoard import `plist`, a Home Screen layout in the form it
/// imports (`buttonBar`, `iconLists` and the App Library's `ignored`),
/// through setIconState, waits for its answer, then reads the layout back on
/// a new connection, as [`atelier_home_screen`] gives it. Free the bytes with
/// [`atelier_device_data_free`].
///
/// # Safety
/// `adapter` and `handshake` must be live handles from the same tunnel,
/// `plist` `length` readable bytes, and `out_plist` and `out_length`
/// writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_set_home_screen(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    plist: *const u8,
    length: libc::size_t,
    out_plist: *mut *mut u8,
    out_length: *mut libc::size_t,
) -> *mut IdeviceFfiError {
    if adapter.is_null()
        || handshake.is_null()
        || plist.is_null()
        || out_plist.is_null()
        || out_length.is_null()
    {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let bytes = unsafe { std::slice::from_raw_parts(plist, length) };
    let layout: plist::Value = match plist::from_bytes(bytes) {
        Ok(layout) => layout,
        Err(e) => {
            return ffi_err!(IdeviceError::UnexpectedResponse(format!(
                "couldn't read the layout to write: {e}"
            )));
        }
    };
    let result = run_sync_local(async move {
        let adapter = unsafe { &mut (*adapter).0 };
        let handshake = unsafe { &mut (*handshake).0 };
        let mut client = SpringBoardServicesClient::connect_rsd(adapter, handshake).await?;
        client.set_icon_state(layout).await?;
        icon_state_set(&mut client.idevice, SET_ICON_STATE_WAIT).await?;
        drop(client);
        let mut client = SpringBoardServicesClient::connect_rsd(adapter, handshake).await?;
        client.get_icon_state(Some("2")).await
    });
    match result {
        Ok(state) => unsafe { write_plist(&state, out_plist, out_length) },
        Err(e) => ffi_err!(e),
    }
}

/// Each app's Home Screen icon, as SpringBoard's getIconPNGData gives it,
/// for Your Gaps' pages: `ids`, a binary plist array of bundle IDs, in, and
/// a binary plist dictionary of bundle ID → PNG data out, without the ones
/// SpringBoard has no icon for. One connection asks for them all, and a new
/// one carries on if it breaks. Free the bytes with
/// [`atelier_device_data_free`].
///
/// # Safety
/// `adapter` and `handshake` must be live handles from the same tunnel,
/// `ids` `length` readable bytes, and `out_plist` and `out_length` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_home_screen_icons(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    ids: *const u8,
    length: libc::size_t,
    out_plist: *mut *mut u8,
    out_length: *mut libc::size_t,
) -> *mut IdeviceFfiError {
    if adapter.is_null()
        || handshake.is_null()
        || ids.is_null()
        || out_plist.is_null()
        || out_length.is_null()
    {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let bytes = unsafe { std::slice::from_raw_parts(ids, length) };
    let ids: Vec<String> = match plist::from_bytes::<plist::Value>(bytes) {
        Ok(plist::Value::Array(ids)) => ids
            .into_iter()
            .filter_map(|id| id.into_string())
            .collect(),
        _ => {
            return ffi_err!(IdeviceError::UnexpectedResponse(
                "couldn't read the bundle IDs to get icons for".into()
            ));
        }
    };
    let result = run_sync_local(async move {
        let adapter = unsafe { &mut (*adapter).0 };
        let handshake = unsafe { &mut (*handshake).0 };
        let mut client = SpringBoardServicesClient::connect_rsd(adapter, handshake).await?;
        let mut icons = plist::Dictionary::new();
        for id in ids {
            match client.get_icon_pngdata(id.clone()).await {
                Ok(png) => {
                    icons.insert(id, plist::Value::Data(png));
                }
                // No icon for it, such as an app that's gone: the
                // connection's still good.
                Err(IdeviceError::UnexpectedResponse(_)) => {}
                Err(_) => {
                    client = SpringBoardServicesClient::connect_rsd(adapter, handshake).await?;
                }
            }
        }
        Ok::<_, IdeviceError>(plist::Value::Dictionary(icons))
    });
    match result {
        Ok(icons) => unsafe { write_plist(&icons, out_plist, out_length) },
        Err(e) => ffi_err!(e),
    }
}

/// The longest SpringBoard takes to answer setIconState, which it does once
/// it has imported the layout: a second or two for 10 pages and 42 folders.
const SET_ICON_STATE_WAIT: Duration = Duration::from_secs(20);

/// Waits for SpringBoard's answer to setIconState, which iOS 27 sends once
/// it has imported the layout, as pymobiledevice3 reads it: an empty
/// message, which idevice's plist reader can't read (6 Nov 2026). A
/// dictionary with an error means SpringBoard refused the layout. An iOS
/// that doesn't answer, as libimobiledevice expects, lets `wait` run out,
/// and one that closes the connection ends it; the read back then shows
/// what it did.
async fn icon_state_set(idevice: &mut Idevice, wait: Duration) -> Result<(), IdeviceError> {
    let Ok(Ok(answer)) = tokio::time::timeout(wait, read_message(idevice)).await else {
        return Ok(());
    };
    if answer.is_empty() {
        return Ok(());
    }
    let Ok(plist::Value::Dictionary(answer)) = plist::from_bytes::<plist::Value>(&answer) else {
        return Ok(());
    };
    match answer.get("error").or_else(|| answer.get("Error")) {
        Some(error) => Err(IdeviceError::UnexpectedResponse(format!(
            "SpringBoard refused the layout: {}",
            error.as_string().map(str::to_owned).unwrap_or_else(|| format!("{error:?}"))
        ))),
        None => Ok(()),
    }
}

/// One message of a service that sends plists after their length, as it
/// came: possibly empty.
async fn read_message(idevice: &mut Idevice) -> Result<Vec<u8>, IdeviceError> {
    let size = idevice.read_raw(4).await?;
    let size = u32::from_be_bytes([size[0], size[1], size[2], size[3]]) as usize;
    if size == 0 {
        return Ok(Vec::new());
    }
    idevice.read_raw(size).await
}

/// Every app installd knows, system apps and the placeholders of apps iOS
/// offloaded too, as a binary plist of bundle ID → name and `SBAppTags`:
/// the apps the App Library is worked out from, as iOS doesn't report it.
/// installd's Lookup, as pymobiledevice3 asks it with placeholders, which
/// idevice's own call doesn't. Free the bytes with
/// [`atelier_device_data_free`].
///
/// # Safety
/// `client` must be a live installation_proxy client, and `out_plist` and
/// `out_length` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_home_screen_apps(
    client: *mut InstallationProxyClientHandle,
    out_plist: *mut *mut u8,
    out_length: *mut libc::size_t,
) -> *mut IdeviceFfiError {
    if client.is_null() || out_plist.is_null() || out_length.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let attributes = ["CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "SBAppTags"]
        .iter()
        .map(|key| plist::Value::String((*key).to_owned()))
        .collect();
    let mut options = plist::Dictionary::new();
    options.insert("ApplicationType".into(), "Any".into());
    options.insert("ShowPlaceholders".into(), true.into());
    options.insert("ReturnAttributes".into(), plist::Value::Array(attributes));
    let mut request = plist::Dictionary::new();
    request.insert("Command".into(), "Lookup".into());
    request.insert("ClientOptions".into(), plist::Value::Dictionary(options));
    let result = run_sync_local(async move {
        let client = unsafe { &mut (*client).0 };
        let mut message = Vec::new();
        plist::Value::Dictionary(request).to_writer_xml(&mut message)?;
        let mut framed = (message.len() as u32).to_be_bytes().to_vec();
        framed.extend_from_slice(&message);
        client.idevice.send_raw(&framed).await?;
        let answer: plist::Dictionary = plist::from_bytes(&read_message(&mut client.idevice).await?)?;
        match answer.get("LookupResult") {
            Some(plist::Value::Dictionary(apps)) => {
                Ok::<_, IdeviceError>(plist::Value::Dictionary(apps.clone()))
            }
            _ => Err(IdeviceError::UnexpectedResponse(format!(
                "installd's Lookup didn't list apps: {}",
                answer
                    .get("Error")
                    .and_then(|e| e.as_string())
                    .unwrap_or("no LookupResult")
            ))),
        }
    });
    match result {
        Ok(apps) => unsafe { write_plist(&apps, out_plist, out_length) },
        Err(e) => ffi_err!(e),
    }
}

/// MCInstall, iOS's configuration profile service, as Apple Configurator
/// talks to it, over the tunnel: Atelier's markers for offloaded apps'
/// spots are web clips, which only a profile makes (9 Nov 2026). idevice
/// has no client for it, so this one checks in and sends plists.
struct ProfileService {
    idevice: Idevice,
}

impl RsdService for ProfileService {
    fn rsd_service_name() -> std::borrow::Cow<'static, str> {
        "com.apple.mobile.MCInstall.shim.remote".into()
    }

    async fn from_stream(stream: Box<dyn idevice::ReadWrite>) -> Result<Self, IdeviceError> {
        let mut idevice = Idevice::new(stream, "atelier");
        idevice.rsd_checkin().await?;
        Ok(Self { idevice })
    }
}

/// How long iOS's profile service may take to answer one request.
const PROFILE_WAIT: Duration = Duration::from_secs(60);

/// Sends `requests`, a binary plist array of MCInstall requests
/// (`RequestType` and their values: `HelloHostIdentifier`,
/// `GetProfileList`, `InstallProfile` with `Payload`, `RemoveProfile` with
/// `ProfileIdentifier`), one after the other on one connection, and answers
/// a binary plist array of what iOS said to each, in order. Swift reads the
/// `Status` of each; this stops only when the connection does. Free the
/// bytes with [`atelier_device_data_free`].
///
/// # Safety
/// `adapter` and `handshake` must be live handles from the same tunnel,
/// `requests` `length` readable bytes, and `out_plist` and `out_length`
/// writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_profile_requests(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    requests: *const u8,
    length: libc::size_t,
    out_plist: *mut *mut u8,
    out_length: *mut libc::size_t,
) -> *mut IdeviceFfiError {
    if adapter.is_null()
        || handshake.is_null()
        || requests.is_null()
        || out_plist.is_null()
        || out_length.is_null()
    {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let bytes = unsafe { std::slice::from_raw_parts(requests, length) };
    let requests = match plist::from_bytes::<plist::Value>(bytes) {
        Ok(plist::Value::Array(requests)) => requests,
        Ok(_) => {
            return ffi_err!(IdeviceError::UnexpectedResponse(
                "the profile requests aren't a list".into()
            ));
        }
        Err(e) => {
            return ffi_err!(IdeviceError::UnexpectedResponse(format!(
                "couldn't read the profile requests: {e}"
            )));
        }
    };
    let result = run_sync_local(async move {
        let adapter = unsafe { &mut (*adapter).0 };
        let handshake = unsafe { &mut (*handshake).0 };
        let mut service = ProfileService::connect_rsd(adapter, handshake).await?;
        let mut answers = Vec::with_capacity(requests.len());
        for request in requests {
            let mut message = Vec::new();
            request.to_writer_xml(&mut message).map_err(|e| {
                IdeviceError::UnexpectedResponse(format!("couldn't write a profile request: {e}"))
            })?;
            let mut framed = (message.len() as u32).to_be_bytes().to_vec();
            framed.extend_from_slice(&message);
            service.idevice.send_raw(&framed).await?;
            let answer = tokio::time::timeout(PROFILE_WAIT, read_message(&mut service.idevice))
                .await
                .map_err(|_| {
                    IdeviceError::UnexpectedResponse(
                        "iOS's profile service didn't answer within a minute".into(),
                    )
                })??;
            let answer = plist::from_bytes::<plist::Value>(&answer).map_err(|e| {
                IdeviceError::UnexpectedResponse(format!(
                    "couldn't read iOS's profile service's answer: {e}"
                ))
            })?;
            answers.push(answer);
        }
        Ok::<_, IdeviceError>(plist::Value::Array(answers))
    });
    match result {
        Ok(answers) => unsafe { write_plist(&answers, out_plist, out_length) },
        Err(e) => ffi_err!(e),
    }
}

/// Hands `value` to Swift as a binary plist, for [`atelier_device_data_free`].
///
/// # Safety
/// `out_plist` and `out_length` must be writable.
unsafe fn write_plist(
    value: &plist::Value,
    out_plist: *mut *mut u8,
    out_length: *mut libc::size_t,
) -> *mut IdeviceFfiError {
    let mut bytes = Vec::new();
    if let Err(e) = value.to_writer_binary(&mut bytes) {
        return ffi_err!(IdeviceError::UnexpectedResponse(format!(
            "couldn't encode the answer: {e}"
        )));
    }
    let bytes = bytes.into_boxed_slice();
    unsafe {
        *out_length = bytes.len();
        *out_plist = Box::into_raw(bytes).cast::<u8>();
    }
    null_mut()
}

fn c_string(s: &str) -> *mut c_char {
    CString::new(s.replace('\0', "")).map_or(null_mut(), CString::into_raw)
}

/// Frees a string from this module.
///
/// # Safety
/// `s` must be NULL or a string this module returned, freed only once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_device_string_free(s: *mut c_char) {
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
pub unsafe extern "C" fn atelier_device_data_free(data: *mut u8, length: libc::size_t) {
    if !data.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(data, length)) });
    }
}
