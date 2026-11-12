//! Free Apple ID signing (#49), the spike: an Apple ID sign-in and the Apple
//! developer calls Atelier needs to sign apps with it, through isideload
//! (MIT, https://github.com/nab138/isideload), for Swift.
//!
//! Sign-in goes through Apple's GrandSlam with anisette data from a remote
//! anisette v3 server, and asks Swift for a verification code when Apple
//! wants one. The developer calls are the ones Xcode makes for a free
//! (Personal Team) or paid team: pick the team, register this iPhone, find
//! or make this iPhone's development certificate, revoke one the user
//! picked at Apple's limit, add an App ID and download its provisioning
//! profile. Structured answers come back as XML plists.
//!
//! Errors carry Apple's code where there is one: `code` says whose it is
//! ([`ATELIER_APPLEID_SIGN_IN_ERROR`], [`ATELIER_APPLEID_DEVELOPER_ERROR`])
//! and `sub_code` is Apple's, such as -20101 for a wrong password, -80045
//! for "This action cannot be completed at this time" or 7460 for the most
//! certificates the team may have.
//!
//! Only builds inside idevice-ffi, which `build-rust.sh` adds it to along
//! with isideload, sharing idevice-ffi's idevice. The crate around
//! `pairing.rs` doesn't build it.

use std::ffi::{CStr, CString, c_char, c_void};
use std::path::{Path, PathBuf};
use std::ptr::null_mut;
use std::sync::Arc;
use std::sync::Once;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::SystemTime;

use isideload::SideloadError;
use isideload::anisette::AnisetteClientInfo;
use isideload::anisette::remote_v3::RemoteV3AnisetteProvider;
use isideload::auth::apple_account::{
    AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse,
};
use isideload::dev::app_groups::AppGroupsApi;
use isideload::dev::app_ids::{AppId, AppIdsApi};
use isideload::dev::certificates::{CertificatesApi, DevelopmentCertificate};
use isideload::dev::developer_session::DeveloperSession;
use isideload::dev::device_type::{DeveloperDeviceType, dev_url};
use isideload::dev::devices::DevicesApi;
use isideload::dev::teams::DeveloperTeam;
use isideload::sideload::builder::MaxCertsBehavior;
use isideload::sideload::cert_identity::CertificateIdentity;
use isideload::util::callbacks::MaxCertsCallbackBox;
use isideload::util::fs_storage::FsStorage;
use isideload::util::storage::SideloadingStorage;
use plist::{Dictionary, Value};
use rootcause::Report;
use rsa::RsaPrivateKey;
use rsa::pkcs1::EncodeRsaPublicKey;
use rsa::pkcs8::DecodePrivateKey;
use sha2::{Digest, Sha256};
use x509_cert::Certificate;
use x509_cert::der::Decode;

use crate::{IdeviceFfiError, ffi_err, run_sync_local};

/// `IdeviceFfiError.code` for an error Apple's sign-in returned;
/// `sub_code` is Apple's code.
pub const ATELIER_APPLEID_SIGN_IN_ERROR: i32 = 9001;
/// `IdeviceFfiError.code` for an error Apple's developer services returned;
/// `sub_code` is Apple's code.
pub const ATELIER_APPLEID_DEVELOPER_ERROR: i32 = 9002;
/// `IdeviceFfiError.code` when the verification code was cancelled.
pub const ATELIER_APPLEID_CANCELLED: i32 = 9003;
/// `IdeviceFfiError.code` when the Apple ID signed in but isn't in any
/// developer team, so it has nothing to sign with.
pub const ATELIER_APPLEID_NO_TEAM: i32 = 9004;
/// `IdeviceFfiError.code` for anything else, such as no network or an
/// anisette server that doesn't answer.
pub const ATELIER_APPLEID_OTHER_ERROR: i32 = 9000;

/// Asks Swift for Apple's verification code, on the thread signing in, which
/// waits for the answer. `request` is an XML plist: `sms` (the code went to
/// a trusted phone number rather than the user's devices), `unknown` (the
/// last way failed, so another must be picked), `numbers` (the trusted
/// numbers, each an `id` and its masked `number`), `selected` (the number
/// the code went to) and `lastError` (why the last code didn't work).
///
/// The answer goes into `response`, NUL-terminated, in at most `capacity`
/// bytes: `code:<the code>`, `sms:<number id>`, `devices` or `resend`.
/// Returning false cancels the sign-in.
pub type AtelierAppleIdCodeCallback = Option<
    unsafe extern "C" fn(
        context: *mut c_void,
        request: *const c_char,
        response: *mut c_char,
        capacity: libc::size_t,
    ) -> bool,
>;

/// A signed-in Apple ID with its developer team picked: the first one Apple
/// lists, or the one [`atelier_appleid_choose_team`] picked. Free with
/// [`atelier_appleid_session_free`].
pub struct AtelierAppleIdSession {
    email: String,
    developer: DeveloperSession,
    team: DeveloperTeam,
    /// Every team Apple lists for the Apple ID, in its order.
    teams: Vec<DeveloperTeam>,
}

/// Signs in to Apple with `email` and `password`, through the anisette v3
/// server at `anisette_url`, sending `client_info` and `user_agent` to Apple
/// in place of the server's when both are given (iloader's override while
/// the servers catch up, 28 Oct 2026). The server's anisette state is kept
/// under `storage_path`, so the next sign-in through it is the same
/// "machine" to Apple. `ask_code` is called when Apple asks for a code.
///
/// An Apple ID in no developer team fails with [`ATELIER_APPLEID_NO_TEAM`].
///
/// On success `out_session` is the session, and `out_info` an XML plist:
/// `teamId`, `teamName`, `teamType`, `teams` (each `teamId`, `name`, `type`,
/// `status`, `memberships`, the names of its programs, and `free`, when
/// they tell whether it's a free team) and `codeAsked`. Free them with
/// [`atelier_appleid_session_free`] and [`atelier_appleid_string_free`].
///
/// # Safety
/// The strings must be valid and NUL-terminated (`client_info` and
/// `user_agent` may be NULL), `context` whatever `ask_code` expects, and
/// `out_session` and `out_info` writable.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn atelier_appleid_sign_in(
    email: *const c_char,
    password: *const c_char,
    anisette_url: *const c_char,
    client_info: *const c_char,
    user_agent: *const c_char,
    storage_path: *const c_char,
    ask_code: AtelierAppleIdCodeCallback,
    context: *mut c_void,
    out_session: *mut *mut AtelierAppleIdSession,
    out_info: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    if out_session.is_null() || out_info.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let Some(ask_code) = ask_code else {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    };
    let (Some(email), Some(password), Some(anisette_url), Some(storage)) = (
        unsafe { string(email) },
        unsafe { string(password) },
        unsafe { string(anisette_url) },
        unsafe { string(storage_path) },
    ) else {
        return ffi_err!(IdeviceError::FfiInvalidString);
    };
    let client_override = match (unsafe { string(client_info) }, unsafe { string(user_agent) }) {
        (Some(client_info), Some(user_agent)) => Some(AnisetteClientInfo {
            client_info,
            user_agent,
        }),
        _ => None,
    };
    setup();

    let email = email.to_lowercase();
    let storage = PathBuf::from(storage);
    let asker = Arc::new(CodeAsker {
        callback: ask_code,
        context: context as usize,
        asked: AtomicBool::new(false),
        cancelled: AtomicBool::new(false),
    });
    let result: Result<Option<(AtelierAppleIdSession, Vec<Dictionary>)>, Report> = run_sync_local({
        let asker = asker.clone();
        let email = email.clone();
        async move {
            let provider = RemoteV3AnisetteProvider::new(
                &anisette_url,
                Box::new(FsStorage::new(anisette_folder(&storage, &anisette_url))),
                "0".to_string(),
            )?
            .set_client_info_override(client_override);
            let ask = move |params: TwoFactorCallbackParams| {
                let asker = asker.clone();
                async move { Ok(asker.ask(&params)) }
            };
            let mut account = AppleAccount::builder(&email)
                .anisette_provider(provider)
                .login(&password, ask)
                .await?;
            let mut developer = DeveloperSession::from_account(&mut account).await?;
            // The teams as Apple lists them, rather than isideload's
            // `list_teams`, which leaves out their memberships.
            let teams: Vec<Dictionary> = developer
                .send_dev_request(&dev_url("listTeams", DeveloperDeviceType::Any), None, "teams")
                .await?;
            let listed: Vec<DeveloperTeam> = teams.iter().filter_map(developer_team).collect();
            let Some(team) = listed.first().cloned() else {
                return Ok(None);
            };
            Ok(Some((
                AtelierAppleIdSession {
                    email,
                    developer,
                    team,
                    teams: listed,
                },
                teams,
            )))
        }
    });
    let (session, teams) = match result {
        Ok(Some(signed_in)) => signed_in,
        Ok(None) => {
            return atelier_error(
                ATELIER_APPLEID_NO_TEAM,
                "This Apple ID isn't in any developer team",
            );
        }
        Err(report) => return apple_error(&report, asker.cancelled.load(Ordering::SeqCst)),
    };

    let mut info = Dictionary::new();
    info.insert("teamId".into(), session.team.team_id.clone().into());
    insert_some(&mut info, "teamName", session.team.name.clone());
    insert_some(&mut info, "teamType", session.team.r#type.clone());
    let teams: Vec<Value> = teams
        .iter()
        .filter_map(|raw| {
            let team = developer_team(raw)?;
            let mut entry = Dictionary::new();
            entry.insert("teamId".into(), team.team_id.into());
            insert_some(&mut entry, "name", team.name);
            insert_some(&mut entry, "type", team.r#type);
            insert_some(&mut entry, "status", team.status);
            let memberships = membership_names(raw);
            if let Some(free) = is_free_team(raw, &memberships) {
                entry.insert("free".into(), free.into());
            }
            entry.insert(
                "memberships".into(),
                Value::Array(memberships.into_iter().map(Value::from).collect()),
            );
            Some(Value::Dictionary(entry))
        })
        .collect();
    info.insert("teams".into(), Value::Array(teams));
    info.insert("codeAsked".into(), asker.asked.load(Ordering::SeqCst).into());
    unsafe {
        *out_info = xml_string(info);
        *out_session = Box::into_raw(Box::new(session));
    }
    null_mut()
}

/// Makes the session's calls use the team `team_id`, one of those the
/// sign-in listed, rather than the first: for an Apple ID in more than one
/// team, such as a paid team and its own Personal Team.
///
/// # Safety
/// `session` must be a live session and `team_id` valid and NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_appleid_choose_team(
    session: *mut AtelierAppleIdSession,
    team_id: *const c_char,
) -> *mut IdeviceFfiError {
    if session.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let Some(team_id) = (unsafe { string(team_id) }) else {
        return ffi_err!(IdeviceError::FfiInvalidString);
    };
    let session = unsafe { &mut *session };
    match session.teams.iter().find(|team| team.team_id == team_id) {
        Some(team) => {
            session.team = team.clone();
            null_mut()
        }
        None => ffi_err!(IdeviceError::FfiInvalidArg),
    }
}

/// Registers the iPhone with `udid` in the session's team under `name`,
/// unless it's there already. `out_info` is an XML plist: `added` and
/// `devices` (how many the team has now).
///
/// # Safety
/// `session` must be a live session, the strings valid and NUL-terminated,
/// and `out_info` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_appleid_register_device(
    session: *mut AtelierAppleIdSession,
    name: *const c_char,
    udid: *const c_char,
    out_info: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    if session.is_null() || out_info.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let (Some(name), Some(udid)) = (unsafe { string(name) }, unsafe { string(udid) }) else {
        return ffi_err!(IdeviceError::FfiInvalidString);
    };
    let session = unsafe { &mut *session };
    let result: Result<(bool, usize), Report> = run_sync_local(async {
        let devices = session.developer.list_devices(&session.team, None).await?;
        if devices
            .iter()
            .any(|device| device.device_number.eq_ignore_ascii_case(&udid))
        {
            return Ok((false, devices.len()));
        }
        session
            .developer
            .add_device(&session.team, &name, &udid, None)
            .await?;
        Ok((true, devices.len() + 1))
    });
    let (added, devices) = match result {
        Ok(registered) => registered,
        Err(report) => return apple_error(&report, false),
    };
    let mut info = Dictionary::new();
    info.insert("added".into(), added.into());
    info.insert("devices".into(), (devices as u64).into());
    unsafe { *out_info = xml_string(info) };
    null_mut()
}

/// The team's iOS development certificates, as an XML plist array: each
/// `name`, `machineName`, `machineId`, `serialNumber`, `status`, `expires`
/// and `content`, the certificate itself (DER), as far as Apple says.
///
/// # Safety
/// `session` must be a live session and `out_info` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_appleid_certificates(
    session: *mut AtelierAppleIdSession,
    out_info: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    if session.is_null() || out_info.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let session = unsafe { &mut *session };
    let result: Result<Vec<DevelopmentCertificate>, Report> =
        run_sync_local(async { session.developer.list_ios_certs(&session.team).await });
    let certificates = match result {
        Ok(certificates) => certificates,
        Err(report) => return apple_error(&report, false),
    };
    let list: Vec<Value> = certificates.iter().map(certificate_info).collect();
    unsafe { *out_info = xml_string_value(Value::Array(list)) };
    null_mut()
}

/// This iPhone's development certificate in the session's team: the one
/// whose key Atelier keeps under `keys_path`, made with `machine_name` when
/// Apple doesn't have it yet, with a key made then and kept there. It never
/// revokes one: at the most certificates the team may have, it fails with
/// Apple's 7460, [`atelier_appleid_certificates`] lists them and
/// [`atelier_appleid_revoke_certificate`] revokes the one the user picks.
///
/// `out_p12` is the certificate and its key as PKCS#12, locked with
/// `p12_password`; `out_info` an XML plist: `serialNumber`, `machineName`,
/// `machineId`, `made` (whether Apple made it now), `certificates` (how
/// many the team has now), and the `name`, `expires` and `content` (the
/// certificate itself, DER) Apple lists.
///
/// # Safety
/// `session` must be a live session, the strings valid and NUL-terminated,
/// and the out pointers writable. Free `out_p12` with
/// [`atelier_appleid_data_free`] and its length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_appleid_certificate(
    session: *mut AtelierAppleIdSession,
    machine_name: *const c_char,
    p12_password: *const c_char,
    keys_path: *const c_char,
    out_p12: *mut *mut u8,
    out_p12_length: *mut libc::size_t,
    out_info: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    if session.is_null() || out_p12.is_null() || out_p12_length.is_null() || out_info.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let (Some(machine_name), Some(p12_password), Some(keys_path)) = (
        unsafe { string(machine_name) },
        unsafe { string(p12_password) },
        unsafe { string(keys_path) },
    ) else {
        return ffi_err!(IdeviceError::FfiInvalidString);
    };
    let session = unsafe { &mut *session };
    let result: Result<(Vec<u8>, Dictionary), Report> = run_sync_local(async {
        let before = session.developer.list_ios_certs(&session.team).await?;
        let keys = FsStorage::new(PathBuf::from(keys_path));
        let identity = CertificateIdentity::retrieve(
            &machine_name,
            &session.email,
            &mut session.developer,
            &session.team,
            &keys,
            &MaxCertsBehavior::<MaxCertsCallbackBox>::Error,
        )
        .await?;
        let p12 = identity.as_p12(&p12_password).await?;
        let serial = identity.get_serial_number();
        let after = session.developer.list_ios_certs(&session.team).await?;
        let made = !before.iter().any(|cert| same_serial(cert, &serial));
        Ok((p12, identity_info(&identity, made, &after)))
    });
    let (p12, info) = match result {
        Ok(made) => made,
        Err(report) => return apple_error(&report, false),
    };
    unsafe {
        write_bytes(p12, out_p12, out_p12_length);
        *out_info = xml_string(info);
    }
    null_mut()
}

/// The team's development certificate made with the RSA key `key` (PKCS#8
/// DER), whatever app or Mac made it and whatever machine name Apple lists
/// it under: the iPhone-only installer hands Atelier the key of the
/// certificate it installed Atelier with (#152), so signing in with that
/// Apple ID doesn't take another of the two certificates a free one may
/// have. With `key` NULL, it's the key Atelier keeps for the session's
/// Apple ID under `keys_path`, as an earlier sign-in left it.
///
/// `out_info` is an XML plist with `found`. When Apple lists one that
/// hasn't run out, `found` is true, `out_p12` and the rest of `out_info` are
/// as [`atelier_appleid_certificate`]'s, with `made` false, and a `key`
/// given is kept under `keys_path` where isideload looks for it, so later
/// sign-ins find the certificate too. Otherwise `out_p12` is NULL, nothing
/// is kept, and `why` says why: `noKey` (none under `keys_path`),
/// `unreadableKey` (not an RSA key in PKCS#8), or `notListed` (Apple lists
/// none made with it, as once it was revoked or ran out), with
/// `certificates`, how many Apple lists.
///
/// # Safety
/// `session` must be a live session, `key` NULL or `key_length` readable
/// bytes, the strings valid and NUL-terminated, and the out pointers
/// writable. Free `out_p12` with [`atelier_appleid_data_free`] and its
/// length.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn atelier_appleid_adopt_certificate(
    session: *mut AtelierAppleIdSession,
    key: *const u8,
    key_length: libc::size_t,
    p12_password: *const c_char,
    keys_path: *const c_char,
    out_p12: *mut *mut u8,
    out_p12_length: *mut libc::size_t,
    out_info: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    if session.is_null() || out_p12.is_null() || out_p12_length.is_null() || out_info.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let (Some(p12_password), Some(keys_path)) =
        (unsafe { string(p12_password) }, unsafe { string(keys_path) })
    else {
        return ffi_err!(IdeviceError::FfiInvalidString);
    };
    let given =
        (!key.is_null()).then(|| unsafe { std::slice::from_raw_parts(key, key_length) }.to_vec());
    let session = unsafe { &mut *session };
    let not_found = |why: &str, listed: Option<usize>| {
        let mut info = Dictionary::new();
        info.insert("found".into(), false.into());
        info.insert("why".into(), why.into());
        if let Some(listed) = listed {
            info.insert("certificates".into(), (listed as u64).into());
        }
        (None, info)
    };
    let result: Result<(Option<Vec<u8>>, Dictionary), Report> = run_sync_local(async {
        let keys = FsStorage::new(PathBuf::from(keys_path));
        let key_name = key_storage_name(&session.email);
        let der = match &given {
            Some(der) => der.clone(),
            None => match keys.retrieve_data(&key_name)? {
                Some(der) if !der.is_empty() => der,
                _ => return Ok(not_found("noKey", None)),
            },
        };
        let Ok(private_key) = RsaPrivateKey::from_pkcs8_der(&der) else {
            return Ok(not_found("unreadableKey", None));
        };
        let listed = session.developer.list_ios_certs(&session.team).await?;
        let Some((cert, certificate)) = made_with(&private_key, &listed, SystemTime::now()) else {
            return Ok(not_found("notListed", Some(listed.len())));
        };
        if given.is_some() {
            keys.store_data(&key_name, &der)?;
        }
        let identity = CertificateIdentity {
            machine_id: cert.machine_id.clone().unwrap_or_default(),
            machine_name: cert.machine_name.clone().unwrap_or_default(),
            private_key,
            certificate,
        };
        let p12 = identity.as_p12(&p12_password).await?;
        let mut info = identity_info(&identity, false, &listed);
        info.insert("found".into(), true.into());
        Ok((Some(p12), info))
    });
    let (p12, info) = match result {
        Ok(answer) => answer,
        Err(report) => return apple_error(&report, false),
    };
    unsafe {
        match p12 {
            Some(p12) => write_bytes(p12, out_p12, out_p12_length),
            None => {
                *out_p12 = null_mut();
                *out_p12_length = 0;
            }
        }
        *out_info = xml_string(info);
    }
    null_mut()
}

/// Revokes the team's development certificate with `serial_number`, as
/// [`atelier_appleid_certificates`] lists it: only one the user picked, at
/// Apple's limit. Apps signed with it stop opening, whichever app signed
/// them.
///
/// # Safety
/// `session` must be a live session and `serial_number` valid and
/// NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_appleid_revoke_certificate(
    session: *mut AtelierAppleIdSession,
    serial_number: *const c_char,
) -> *mut IdeviceFfiError {
    if session.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let Some(serial_number) = (unsafe { string(serial_number) }) else {
        return ffi_err!(IdeviceError::FfiInvalidString);
    };
    let session = unsafe { &mut *session };
    let result: Result<(), Report> = run_sync_local(async {
        session
            .developer
            .revoke_development_cert(&session.team, &serial_number, None)
            .await
    });
    match result {
        Ok(()) => null_mut(),
        Err(report) => apple_error(&report, false),
    }
}

/// The team's App IDs, as an XML plist: `appIds` (each `identifier`, `name`
/// and `expires`), `max` and `available`, as far as Apple says. A free team
/// may register 10 in 7 days.
///
/// # Safety
/// `session` must be a live session and `out_info` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_appleid_app_ids(
    session: *mut AtelierAppleIdSession,
    out_info: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    if session.is_null() || out_info.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let session = unsafe { &mut *session };
    let result = run_sync_local(async {
        session
            .developer
            .list_app_ids(&session.team, None)
            .await
    });
    let response = match result {
        Ok(response) => response,
        Err(report) => return apple_error(&report, false),
    };
    let app_ids: Vec<Value> = response
        .app_ids
        .iter()
        .map(|app_id| {
            let mut entry = Dictionary::new();
            entry.insert("identifier".into(), app_id.identifier.clone().into());
            entry.insert("name".into(), app_id.name.clone().into());
            if let Some(expires) = app_id.expiration_date {
                entry.insert("expires".into(), Value::Date(expires));
            }
            Value::Dictionary(entry)
        })
        .collect();
    let mut info = Dictionary::new();
    info.insert("appIds".into(), Value::Array(app_ids));
    if let Some(max) = response.max_quantity {
        info.insert("max".into(), max.into());
    }
    if let Some(available) = response.available_quantity {
        info.insert("available".into(), available.into());
    }
    unsafe { *out_info = xml_string(info) };
    null_mut()
}

/// The provisioning profile for the App ID `bundle_id`, which this adds to
/// the team first, under `name`, when it isn't there: one of the 10 a free
/// team may add in 7 days. Apple makes the profile for the team's
/// registered devices and its certificates.
///
/// `groups`, an XML plist array of strings or NULL, are the App Groups the
/// app is to be signed with, as the team has them: each is added to the
/// team when it isn't there, the App ID gets App Groups turned on, and the
/// groups are assigned to it, as AltSign does, so the profile allows them.
/// That step failing doesn't stop the profile, which then allows none:
/// `groupsError` says why.
///
/// `out_profile` is the profile as Apple sends it; `out_info` an XML plist:
/// `added` (whether the App ID was added now), `available` and `max` (as
/// they were before), `appIdExpires`, `uuid`, `name`, `expires`, and with
/// groups asked for, `groups` (those assigned), `groupsAdded` (those added
/// to the team now) or `groupsError`.
///
/// # Safety
/// `session` must be a live session, the strings valid and NUL-terminated
/// (`groups` may be NULL), and the out pointers writable. Free
/// `out_profile` with [`atelier_appleid_data_free`] and its length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_appleid_profile(
    session: *mut AtelierAppleIdSession,
    bundle_id: *const c_char,
    name: *const c_char,
    groups: *const c_char,
    out_profile: *mut *mut u8,
    out_profile_length: *mut libc::size_t,
    out_info: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    if session.is_null()
        || out_profile.is_null()
        || out_profile_length.is_null()
        || out_info.is_null()
    {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let (Some(bundle_id), Some(name)) = (unsafe { string(bundle_id) }, unsafe { string(name) })
    else {
        return ffi_err!(IdeviceError::FfiInvalidString);
    };
    let wanted = if groups.is_null() {
        Vec::new()
    } else {
        match unsafe { string(groups) }.and_then(|text| group_list(&text)) {
            Some(wanted) => wanted,
            None => return ffi_err!(IdeviceError::FfiInvalidString),
        }
    };
    let session = unsafe { &mut *session };
    let result: Result<(Vec<u8>, Dictionary), Report> = run_sync_local(async {
        let listed = session
            .developer
            .list_app_ids(&session.team, None)
            .await?;
        let existing = listed
            .app_ids
            .iter()
            .find(|app_id| app_id.identifier == bundle_id)
            .cloned();
        let added = existing.is_none();
        let mut app_id = match existing {
            Some(app_id) => app_id,
            None => {
                session
                    .developer
                    .add_app_id(&session.team, &name, &bundle_id, None)
                    .await?
            }
        };
        // Before the profile, which allows the groups the App ID has then.
        let groups = if wanted.is_empty() {
            None
        } else {
            Some(assign_groups(session, &mut app_id, &wanted).await)
        };
        let profile = session
            .developer
            .download_team_provisioning_profile(&session.team, &app_id, None)
            .await?;

        let mut info = Dictionary::new();
        info.insert("added".into(), added.into());
        if let Some(available) = listed.available_quantity {
            info.insert("available".into(), available.into());
        }
        if let Some(max) = listed.max_quantity {
            info.insert("max".into(), max.into());
        }
        if let Some(expires) = app_id.expiration_date {
            info.insert("appIdExpires".into(), Value::Date(expires));
        }
        info.insert("uuid".into(), profile.uuid.clone().into());
        info.insert("name".into(), profile.name.clone().into());
        info.insert("expires".into(), Value::Date(profile.date_expire));
        match groups {
            Some(Ok((assigned, added_now))) => {
                info.insert("groups".into(), strings(assigned));
                info.insert("groupsAdded".into(), strings(added_now));
            }
            Some(Err(report)) => {
                info.insert("groupsError".into(), report_message(&report).into());
            }
            None => {}
        }
        let bytes: Vec<u8> = profile.encoded_profile.into();
        Ok((bytes, info))
    });
    let (profile, info) = match result {
        Ok(downloaded) => downloaded,
        Err(report) => return apple_error(&report, false),
    };
    unsafe {
        write_bytes(profile, out_profile, out_profile_length);
        *out_info = xml_string(info);
    }
    null_mut()
}

/// Frees a session.
///
/// # Safety
/// `session` must be NULL or a session from [`atelier_appleid_sign_in`],
/// freed only once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_appleid_session_free(session: *mut AtelierAppleIdSession) {
    if !session.is_null() {
        drop(unsafe { Box::from_raw(session) });
    }
}

/// Frees a string from this module.
///
/// # Safety
/// `s` must be NULL or a string this module returned, freed only once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atelier_appleid_string_free(s: *mut c_char) {
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
pub unsafe extern "C" fn atelier_appleid_data_free(data: *mut u8, length: libc::size_t) {
    if !data.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(data, length)) });
    }
}

/// Swift's verification code prompt, and what became of it.
struct CodeAsker {
    callback: unsafe extern "C" fn(*mut c_void, *const c_char, *mut c_char, libc::size_t) -> bool,
    /// Swift's context pointer, kept as a number so the asker can cross
    /// threads; Swift answers from any.
    context: usize,
    asked: AtomicBool,
    cancelled: AtomicBool,
}

impl CodeAsker {
    fn ask(&self, params: &TwoFactorCallbackParams) -> TwoFactorCallbackResponse {
        self.asked.store(true, Ordering::SeqCst);
        let mut request = Dictionary::new();
        request.insert("sms".into(), params.sms.into());
        request.insert("unknown".into(), params.unknown.into());
        let numbers: Vec<Value> = params
            .numbers
            .iter()
            .map(|number| {
                let mut entry = Dictionary::new();
                entry.insert("id".into(), u64::from(number.id).into());
                entry.insert("number".into(), number.number_with_dial_code.clone().into());
                Value::Dictionary(entry)
            })
            .collect();
        request.insert("numbers".into(), Value::Array(numbers));
        if let Some(selected) = params.selected_number_id {
            request.insert("selected".into(), u64::from(selected).into());
        }
        insert_some(&mut request, "lastError", params.last_error.clone());
        let request = xml_string(request);
        if request.is_null() {
            self.cancelled.store(true, Ordering::SeqCst);
            return TwoFactorCallbackResponse::Abort;
        }

        let mut response = vec![0 as c_char; 128];
        let answered = unsafe {
            (self.callback)(
                self.context as *mut c_void,
                request,
                response.as_mut_ptr(),
                response.len(),
            )
        };
        unsafe { atelier_appleid_string_free(request) };
        if !answered {
            self.cancelled.store(true, Ordering::SeqCst);
            return TwoFactorCallbackResponse::Abort;
        }
        // Whatever Swift wrote, the last byte ends the string.
        if let Some(last) = response.last_mut() {
            *last = 0;
        }
        let answer = unsafe { CStr::from_ptr(response.as_ptr()) }
            .to_string_lossy()
            .trim()
            .to_string();
        if let Some(code) = answer.strip_prefix("code:") {
            TwoFactorCallbackResponse::SubmitCode(code.trim().to_string())
        } else if let Some(id) = answer.strip_prefix("sms:").and_then(|id| id.trim().parse().ok()) {
            TwoFactorCallbackResponse::SendSms(id)
        } else if answer == "devices" {
            TwoFactorCallbackResponse::SendToDevices
        } else if answer == "resend" {
            TwoFactorCallbackResponse::ResendCode
        } else {
            self.cancelled.store(true, Ordering::SeqCst);
            TwoFactorCallbackResponse::Abort
        }
    }
}

/// The App ID feature that turns App Groups on, as AltSign names it.
const APP_GROUPS_FEATURE: &str = "APG3427HIY";

/// Adds each of `wanted` to the team when it isn't there, turns App Groups
/// on for `app_id` and assigns it the groups, which takes the place of any
/// it had. Returns the groups assigned and those added now.
async fn assign_groups(
    session: &mut AtelierAppleIdSession,
    app_id: &mut AppId,
    wanted: &[String],
) -> Result<(Vec<String>, Vec<String>), Report> {
    let existing = session
        .developer
        .list_app_groups(&session.team, None)
        .await?;
    let mut groups = Vec::new();
    let mut added = Vec::new();
    for identifier in wanted {
        if let Some(group) = existing
            .iter()
            .find(|group| group.identifier.eq_ignore_ascii_case(identifier))
        {
            groups.push(group.clone());
            continue;
        }
        // isideload keeps only its letters and digits, which Apple takes.
        let group = session
            .developer
            .add_app_group(&session.team, &format!("Atelier {identifier}"), identifier, None)
            .await?;
        added.push(group.identifier.clone());
        groups.push(group);
    }
    if !has_group_feature(&app_id.features) {
        let mut features = Dictionary::new();
        features.insert(APP_GROUPS_FEATURE.into(), true.into());
        let updated = session
            .developer
            .update_app_id(&session.team, app_id, features, None)
            .await?;
        app_id.features = updated.features;
    }
    // Apple's own IDs for the groups, as a list, as AltSign sends them.
    let mut body = Dictionary::new();
    body.insert("teamId".into(), session.team.team_id.clone().into());
    body.insert("appIdId".into(), app_id.app_id_id.clone().into());
    body.insert(
        "applicationGroups".into(),
        Value::Array(
            groups
                .iter()
                .map(|group| group.application_group.clone().into())
                .collect(),
        ),
    );
    session
        .developer
        .send_dev_request_no_response(&dev_url("assignApplicationGroupToAppId", None), body)
        .await?;
    Ok((groups.into_iter().map(|group| group.identifier).collect(), added))
}

/// Whether an App ID's features have App Groups on.
fn has_group_feature(features: &Dictionary) -> bool {
    features
        .get(APP_GROUPS_FEATURE)
        .and_then(Value::as_boolean)
        .unwrap_or(false)
}

/// The strings in `text`, an XML plist array of them; None when it isn't
/// one.
fn group_list(text: &str) -> Option<Vec<String>> {
    let value: Value = plist::from_bytes(text.as_bytes()).ok()?;
    value
        .as_array()?
        .iter()
        .map(|entry| entry.as_string().map(str::to_string))
        .collect()
}

fn strings(values: Vec<String>) -> Value {
    Value::Array(values.into_iter().map(Value::from).collect())
}

/// Sets up what isideload needs once: rustls' process-wide crypto provider,
/// which its HTTPS client takes (ring, the one idevice installs itself when
/// ring is on, as isideload turns it on), and its error reports' formatting.
fn setup() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let _ = isideload::init();
    });
}

/// isideload's team from one of Apple's `listTeams` entries.
fn developer_team(raw: &Dictionary) -> Option<DeveloperTeam> {
    let text = |key: &str| raw.get(key).and_then(Value::as_string).map(str::to_string);
    Some(DeveloperTeam {
        team_id: text("teamId")?,
        name: text("name"),
        r#type: text("type"),
        status: text("status"),
    })
}

/// The names of a team's memberships, its developer programs.
fn membership_names(raw: &Dictionary) -> Vec<String> {
    raw.get("memberships")
        .and_then(Value::as_array)
        .map(|memberships| {
            memberships
                .iter()
                .filter_map(|membership| {
                    let membership = membership.as_dictionary()?;
                    membership.get("name").and_then(Value::as_string).map(str::to_string)
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Whether a team is a free Apple ID's, which Xcode calls a Personal Team.
/// Apple lists it as "Individual", like a paid individual's, so the type
/// can't tell: the team has a single membership, Xcode's free program, the
/// test AltSign makes. Apple's `xcodeFreeOnly` only counts when it's true
/// and there are no memberships: it was false for a free Apple ID's team,
/// whose only membership was the Xcode Free Provisioning Program (a
/// sign-in of 3 Nov 2026). None when there's nothing to go by.
fn is_free_team(raw: &Dictionary, memberships: &[String]) -> Option<bool> {
    if !memberships.is_empty() {
        return Some(memberships.len() == 1 && memberships[0].to_lowercase().contains("free"));
    }
    match raw.get("xcodeFreeOnly").and_then(Value::as_boolean) {
        Some(true) => Some(true),
        _ => None,
    }
}

/// The folder for one anisette server's state, so switching servers never
/// mixes their states.
fn anisette_folder(storage: &Path, url: &str) -> PathBuf {
    let host: String = url
        .trim_start_matches("https://")
        .trim_start_matches("http://")
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '.' || c == '-' { c } else { '_' })
        .collect();
    storage.join("anisette").join(host)
}

/// Whether Apple's certificate has `serial`, as isideload writes it: upper
/// case hex without leading zeros.
fn same_serial(cert: &DevelopmentCertificate, serial: &str) -> bool {
    cert.serial_number
        .as_deref()
        .is_some_and(|s| s.trim_start_matches('0').eq_ignore_ascii_case(serial))
}

/// What [`atelier_appleid_certificate`] and
/// [`atelier_appleid_adopt_certificate`] say about the certificate:
/// `listed` is the team's certificates as Apple lists them now.
fn identity_info(
    identity: &CertificateIdentity,
    made: bool,
    listed: &[DevelopmentCertificate],
) -> Dictionary {
    let serial = identity.get_serial_number();
    let mut info = Dictionary::new();
    info.insert("serialNumber".into(), serial.clone().into());
    info.insert("machineName".into(), identity.machine_name.clone().into());
    info.insert("machineId".into(), identity.machine_id.clone().into());
    info.insert("made".into(), made.into());
    info.insert("certificates".into(), (listed.len() as u64).into());
    if let Some(cert) = listed.iter().find(|cert| same_serial(cert, &serial)) {
        insert_some(&mut info, "name", cert.name.clone());
        if let Some(expires) = cert.expiration_date {
            info.insert("expires".into(), Value::Date(expires));
        }
        if let Some(content) = &cert.cert_content {
            info.insert("content".into(), Value::Data(content.clone().into()));
        }
    }
    info
}

/// Where isideload keeps the certificate's key for the Apple ID `email`
/// under the keys folder, as `CertificateIdentity::retrieve` reads it: the
/// hex SHA-256 of the Apple ID as the session has it, in lower case.
fn key_storage_name(email: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(email.as_bytes());
    format!("{}/key", hex::encode(hasher.finalize()))
}

/// The certificate among `listed` made with `private_key`, as isideload's
/// `find_matching` tells (the certificate's public key is the key's), that
/// hasn't run out by `now`, whatever machine name Apple lists it under.
fn made_with(
    private_key: &RsaPrivateKey,
    listed: &[DevelopmentCertificate],
    now: SystemTime,
) -> Option<(DevelopmentCertificate, Certificate)> {
    let public_key = private_key.to_public_key().to_pkcs1_der().ok()?;
    listed
        .iter()
        .filter(|cert| cert.serial_number.is_some())
        .filter(|cert| {
            cert.expiration_date
                .is_none_or(|ends| SystemTime::from(ends) > now)
        })
        .find_map(|cert| {
            let certificate = Certificate::from_der(cert.cert_content.as_ref()?.as_ref()).ok()?;
            let theirs = certificate
                .tbs_certificate
                .subject_public_key_info
                .subject_public_key
                .as_bytes()?;
            (theirs == public_key.as_bytes()).then(|| (cert.clone(), certificate))
        })
}

fn certificate_info(cert: &DevelopmentCertificate) -> Value {
    let mut entry = Dictionary::new();
    insert_some(&mut entry, "name", cert.name.clone());
    insert_some(&mut entry, "machineName", cert.machine_name.clone());
    insert_some(&mut entry, "machineId", cert.machine_id.clone());
    insert_some(&mut entry, "serialNumber", cert.serial_number.clone());
    insert_some(&mut entry, "status", cert.status.clone());
    if let Some(expires) = cert.expiration_date {
        entry.insert("expires".into(), Value::Date(expires));
    }
    if let Some(content) = &cert.cert_content {
        entry.insert("content".into(), Value::Data(content.clone().into()));
    }
    Value::Dictionary(entry)
}

/// An error for Swift, with Apple's code when the report has one. The
/// message is the report's chain of contexts, without its attachments,
/// which can hold Apple's whole answer.
fn apple_error(report: &Report, cancelled: bool) -> *mut IdeviceFfiError {
    let mut code = ATELIER_APPLEID_OTHER_ERROR;
    let mut sub_code = 0;
    for node in report.iter_reports() {
        match node.downcast_current_context::<SideloadError>() {
            Some(SideloadError::AuthWithMessage(apple, _)) => {
                code = ATELIER_APPLEID_SIGN_IN_ERROR;
                sub_code = *apple as i32;
                break;
            }
            Some(SideloadError::DeveloperError(apple, _)) => {
                code = ATELIER_APPLEID_DEVELOPER_ERROR;
                sub_code = *apple as i32;
                break;
            }
            _ => {}
        }
    }
    if cancelled {
        code = ATELIER_APPLEID_CANCELLED;
    }
    let message = CString::new(report_message(report).replace('\0', "")).unwrap_or_default();
    Box::into_raw(Box::new(IdeviceFfiError {
        code,
        sub_code,
        message: message.into_raw(),
    }))
}

/// The report's chain of contexts, without its attachments, which can hold
/// Apple's whole answer.
fn report_message(report: &Report) -> String {
    report
        .iter_reports()
        .map(|node| node.format_current_context().to_string())
        .filter(|line| !line.trim().is_empty())
        .collect::<Vec<_>>()
        .join(": ")
}

/// An error of Atelier's own for Swift, with no code of Apple's.
fn atelier_error(code: i32, message: &str) -> *mut IdeviceFfiError {
    let message = CString::new(message.replace('\0', "")).unwrap_or_default();
    Box::into_raw(Box::new(IdeviceFfiError {
        code,
        sub_code: 0,
        message: message.into_raw(),
    }))
}

unsafe fn string(s: *const c_char) -> Option<String> {
    if s.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(s) }.to_str().ok().map(str::to_owned)
}

fn insert_some(dictionary: &mut Dictionary, key: &str, value: Option<String>) {
    if let Some(value) = value {
        dictionary.insert(key.into(), value.into());
    }
}

fn xml_string(dictionary: Dictionary) -> *mut c_char {
    xml_string_value(Value::Dictionary(dictionary))
}

fn xml_string_value(value: Value) -> *mut c_char {
    let mut bytes = Vec::new();
    if value.to_writer_xml(&mut bytes).is_err() {
        return null_mut();
    }
    CString::new(bytes).map_or(null_mut(), CString::into_raw)
}

unsafe fn write_bytes(bytes: Vec<u8>, out: *mut *mut u8, out_length: *mut libc::size_t) {
    let bytes = bytes.into_boxed_slice();
    unsafe {
        *out_length = bytes.len();
        *out = Box::into_raw(bytes).cast::<u8>();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use x509_cert::der::Encode;

    /// One `listTeams` entry, as Apple's XML plist gives it.
    fn team(body: &str) -> Dictionary {
        let xml = format!(
            r#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>teamId</key><string>A1B2C3D4E5</string><key>name</key><string>Sam Test</string><key>type</key><string>Individual</string><key>status</key><string>active</string>{body}</dict></plist>"#
        );
        plist::from_bytes(xml.as_bytes()).unwrap()
    }

    fn free(body: &str) -> Option<bool> {
        let raw = team(body);
        is_free_team(&raw, &membership_names(&raw))
    }

    /// A 512-bit RSA key, PKCS#8 DER in hex: small, as only its public half counts.
    const KEY_A: &str = concat!(
        "30820154020100300d06092a864886f70d01010105000482013e3082013a0201000241009efc4f04",
        "db32af2dff03618b7f5ac9d38065f1aa2b6e7fed64183e4607e13abb40cf377b7054155d80a3490a",
        "f0ea96446c708016cf10ce2833667693911595110203010001024054a8a22341dde16eaac6d0208a",
        "367c1685dec32b0c6990f186456a93bc0a714d02127d0745b8f87c572fc770d0f67ad87b0ce5f8b0",
        "c0ec8700d0150a4a7572a9022100d2292d417975e4800e3b3b957822b80f385dd3c908252e10740c",
        "4c2822e1dbeb022100c1a9a419df645bd02474f1ae82ce71315c3ba0beee81a8dde37acf7be8f93f",
        "f3022063ae8e3da90bc7270a19044900238fa4007b5891d8e031ba3221071a5e793ca30220337b73",
        "62655e7a81d48f3a085841a519a81939dc47ef3402f88c17482b60c73d022100ce13346a85e7acc8",
        "5a8084b8dd765da5df3bcdd96f8ece3188116303d5073c6b",
    );
    /// A certificate made with `KEY_A`, DER in hex.
    const CERT_A: &str = concat!(
        "308201753082011fa00302010202142a24811784b4716be95dac393e6aabc211ef10e7300d06092a",
        "864886f70d01010b0500300f310d300b06035504030c0454657374301e170d323631313132313234",
        "3035365a170d3336313130393132343035365a300f310d300b06035504030c0454657374305c300d",
        "06092a864886f70d0101010500034b0030480241009efc4f04db32af2dff03618b7f5ac9d38065f1",
        "aa2b6e7fed64183e4607e13abb40cf377b7054155d80a3490af0ea96446c708016cf10ce28336676",
        "93911595110203010001a3533051301d0603551d0e04160414f4f3dff06186dc25addbb27886c87c",
        "62485cd590301f0603551d23041830168014f4f3dff06186dc25addbb27886c87c62485cd590300f",
        "0603551d130101ff040530030101ff300d06092a864886f70d01010b0500034100214ae84071e0bb",
        "2887cb048ab07eb0b2469d01a0a41bc30ffafa03a3a10a5cd83830ab287ad1d74dd3f01669e84f3d",
        "595ce589229a33c5e960b496f6ab24baac",
    );
    /// A certificate made with another key.
    const CERT_B: &str = concat!(
        "308201753082011fa00302010202144013f3b0a92fa2922831e0950bd12164eb40aa04300d06092a",
        "864886f70d01010b0500300f310d300b06035504030c0454657374301e170d323631313132313234",
        "3035365a170d3336313130393132343035365a300f310d300b06035504030c0454657374305c300d",
        "06092a864886f70d0101010500034b00304802410099e3dcd66c7372157cf62aa4b269522bc6a4f5",
        "91093dca50c7be2a0ca529d96d103f0c59bd8ba7e941cf0514b9b553f32f1d4a5538ff9f8f6ea8a7",
        "f9919b878f0203010001a3533051301d0603551d0e04160414fa0b7ff7c96873bf99c1dedaa28519",
        "40ad59f811301f0603551d23041830168014fa0b7ff7c96873bf99c1dedaa2851940ad59f811300f",
        "0603551d130101ff040530030101ff300d06092a864886f70d01010b0500034100358fbc302a54fc",
        "235af6824b414f230852d64cb2d5cacc76285d841b17537e6adeb72a5c03dc79920e5ef39b08cca8",
        "39411265218053b6b3f493f27f7c320da9",
    );

    fn listed(
        serial: Option<&str>,
        content: &str,
        machine: &str,
        ends: SystemTime,
    ) -> DevelopmentCertificate {
        DevelopmentCertificate {
            name: Some("iOS Development: Sam Test".into()),
            certificate_id: Some("ABCDEF1234".into()),
            serial_number: serial.map(str::to_owned),
            machine_id: Some("0E5B1D2C-0000-4000-8000-000000000001".into()),
            machine_name: Some(machine.into()),
            cert_content: Some(plist::Data::new(hex::decode(content).unwrap())),
            certificate_platform: Some("ios".into()),
            certificate_type: None,
            status: Some("Issued".into()),
            status_code: Some(0),
            expiration_date: Some(plist::Date::from(ends)),
        }
    }

    #[test]
    fn the_key_is_kept_where_isideload_looks() {
        // The hex SHA-256 of the Apple ID, as the session has it.
        assert_eq!(
            key_storage_name("sam.test@icloud.com"),
            "c74063d8c2ae167eebcff7b2534ba2ccb621c97494d69daac9fa299709e0251b/key"
        );
    }

    #[test]
    fn the_certificate_made_with_the_key_whatever_its_machine() {
        let key = RsaPrivateKey::from_pkcs8_der(&hex::decode(KEY_A).unwrap()).unwrap();
        let now = SystemTime::now();
        let later = now + std::time::Duration::from_secs(86_400);
        let theirs = listed(Some("1A2B"), CERT_B, "AltStore", later);
        let installers = listed(Some("3C4D"), CERT_A, "Atelier Installer", later);
        let (found, certificate) = made_with(&key, &[theirs.clone(), installers], now).unwrap();
        assert_eq!(found.serial_number.as_deref(), Some("3C4D"));
        assert_eq!(found.machine_name.as_deref(), Some("Atelier Installer"));
        assert_eq!(certificate.to_der().unwrap(), hex::decode(CERT_A).unwrap());
        // Another key's only.
        assert!(made_with(&key, &[theirs], now).is_none());
    }

    #[test]
    fn not_one_that_ran_out_or_has_no_serial() {
        let key = RsaPrivateKey::from_pkcs8_der(&hex::decode(KEY_A).unwrap()).unwrap();
        let now = SystemTime::now();
        let earlier = now - std::time::Duration::from_secs(60);
        let later = now + std::time::Duration::from_secs(86_400);
        assert!(made_with(&key, &[listed(Some("3C4D"), CERT_A, "Atelier", earlier)], now).is_none());
        assert!(made_with(&key, &[listed(None, CERT_A, "Atelier", later)], now).is_none());
        let mut no_content = listed(Some("3C4D"), CERT_A, "Atelier", later);
        no_content.cert_content = None;
        assert!(made_with(&key, &[no_content], now).is_none());
    }

    #[test]
    fn groups_come_as_a_plist_list() {
        let xml = r#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><array><string>group.com.example.chat.A1B2C3D4E5</string><string>group.com.example.other.A1B2C3D4E5</string></array></plist>"#;
        assert_eq!(
            group_list(xml),
            Some(vec![
                "group.com.example.chat.A1B2C3D4E5".to_string(),
                "group.com.example.other.A1B2C3D4E5".to_string()
            ])
        );
        let empty = r#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><array/></plist>"#;
        assert_eq!(group_list(empty), Some(vec![]));
        // Anything but a list of strings.
        let mixed = r#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><array><string>group.a</string><integer>1</integer></array></plist>"#;
        assert_eq!(group_list(mixed), None);
        assert_eq!(group_list("<plist><dict/></plist>"), None);
    }

    #[test]
    fn the_app_ids_features_say_whether_groups_are_on() {
        let features = |body: &str| -> Dictionary {
            let xml = format!(r#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>{body}</dict></plist>"#);
            plist::from_bytes(xml.as_bytes()).unwrap()
        };
        assert!(has_group_feature(&features("<key>APG3427HIY</key><true/>")));
        assert!(!has_group_feature(&features("<key>APG3427HIY</key><false/>")));
        // A new App ID's, which may not list it.
        assert!(!has_group_feature(&features("<key>push</key><false/>")));
    }

    #[test]
    fn the_program_tells_before_xcode_free_only() {
        // A free Apple ID's team, as Apple listed it on 3 Nov 2026.
        assert_eq!(
            free("<key>xcodeFreeOnly</key><false/><key>memberships</key><array><dict><key>name</key><string>Xcode Free Provisioning Program</string></dict></array>"),
            Some(true)
        );
        assert_eq!(
            free("<key>xcodeFreeOnly</key><true/><key>memberships</key><array><dict><key>name</key><string>Apple Developer Program</string></dict></array>"),
            Some(false)
        );
    }

    #[test]
    fn xcode_free_only_counts_only_when_true() {
        assert_eq!(free("<key>xcodeFreeOnly</key><true/>"), Some(true));
        assert_eq!(free("<key>xcodeFreeOnly</key><false/>"), None);
    }

    #[test]
    fn a_single_free_program_is_a_free_team() {
        assert_eq!(
            free("<key>memberships</key><array><dict><key>name</key><string>Xcode Free Provisioning Program</string><key>platform</key><string>ios</string></dict></array>"),
            Some(true)
        );
    }

    #[test]
    fn a_paid_program_is_not() {
        assert_eq!(
            free("<key>memberships</key><array><dict><key>name</key><string>Apple Developer Program</string></dict></array>"),
            Some(false)
        );
    }

    #[test]
    fn nothing_to_go_by_is_unknown() {
        assert_eq!(free(""), None);
        assert_eq!(free("<key>memberships</key><array/>"), None);
    }

    #[test]
    fn the_team_and_its_program_names() {
        let raw = team("<key>memberships</key><array><dict><key>name</key><string>Xcode Free Provisioning Program</string></dict><dict><key>platform</key><string>ios</string></dict></array>");
        let parsed = developer_team(&raw).unwrap();
        assert_eq!(parsed.team_id, "A1B2C3D4E5");
        assert_eq!(parsed.name.as_deref(), Some("Sam Test"));
        assert_eq!(parsed.r#type.as_deref(), Some("Individual"));
        assert_eq!(parsed.status.as_deref(), Some("active"));
        assert_eq!(membership_names(&raw), ["Xcode Free Provisioning Program"]);
        assert!(developer_team(&Dictionary::new()).is_none());
    }
}
