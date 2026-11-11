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
use plist::{Dictionary, Value};
use rootcause::Report;

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

        let mut info = Dictionary::new();
        info.insert("serialNumber".into(), serial.clone().into());
        info.insert("machineName".into(), identity.machine_name.clone().into());
        info.insert("machineId".into(), identity.machine_id.clone().into());
        let made = !before.iter().any(|cert| same_serial(cert, &serial));
        info.insert("made".into(), made.into());
        info.insert("certificates".into(), (after.len() as u64).into());
        if let Some(cert) = after.iter().find(|cert| same_serial(cert, &serial)) {
            insert_some(&mut info, "name", cert.name.clone());
            if let Some(expires) = cert.expiration_date {
                info.insert("expires".into(), Value::Date(expires));
            }
            if let Some(content) = &cert.cert_content {
                info.insert("content".into(), Value::Data(content.clone().into()));
            }
        }
        Ok((p12, info))
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
