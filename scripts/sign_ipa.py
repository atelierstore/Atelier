#!/usr/bin/env python3
"""Signs an unsigned app (Atelier, or the install spike) with the provisioning
profile and certificate that CI installs (the SIGNING_* secrets in
.github/workflows/build.yml), the way Feather re-signs an IPA on the phone, and
packages it as an IPA. Runs on macOS.

Like Feather (zsign), it signs with the profile's entitlements as they are and
keeps the app's own bundle ID, even when the profile was made for another app.
App extensions in PlugIns (the install spike's Live Activity, #54) are signed
the same way, with the same profile, before the app.

Usage: python3 scripts/sign_ipa.py <path to the .app> <output .ipa>

The exit code says what went wrong, as a CI's summary may show only that:
  10  no provisioning profile is installed
  11  more than one provisioning profile is installed
  14  no certificate in the keychain belongs to the profile
  15  the app has an Extensions folder (ExtensionKit), which this script doesn't sign
  16  codesign failed to sign the app
  17  the signed app doesn't verify
"""

import fnmatch
import hashlib
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

PROFILE_DIRS = (
    # Xcode 16 and newer read profiles from the first, older Xcode from the second.
    pathlib.Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
    pathlib.Path.home() / "Library/MobileDevice/Provisioning Profiles",
)


def fail(code, message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(code)


def installed_profiles():
    """Each installed profile once, as (path, decoded profile)."""
    found = {}
    for directory in PROFILE_DIRS:
        for path in sorted(directory.glob("*.mobileprovision")):
            decoded = subprocess.run(
                ["security", "cms", "-D", "-i", str(path)],
                check=True,
                capture_output=True,
            ).stdout
            profile = plistlib.loads(decoded)
            found.setdefault(profile["UUID"], (path, profile))
    return list(found.values())


def profile_kind(profile):
    if profile.get("ProvisionsAllDevices"):
        return "in-house"
    if profile["Entitlements"].get("get-task-allow"):
        return "development"
    return "ad hoc"


def covers(profile, bundle_id):
    """Whether the profile's app ID, <prefix>.<bundle ID or wildcard pattern>,
    covers bundle_id. The prefix is usually the team ID, but older teams can
    have a different one."""
    _, _, pattern = profile["Entitlements"]["application-identifier"].partition(".")
    return fnmatch.fnmatchcase(bundle_id, pattern)


def certificate_fingerprints(profile):
    """SHA-1 fingerprints of the certificates the profile accepts, written the
    way `security find-identity` prints them."""
    return [
        hashlib.sha1(der).hexdigest().upper()
        for der in profile["DeveloperCertificates"]
    ]


def identity_fingerprints(find_identity_output):
    return set(
        re.findall(r"^\s*\d+\)\s+([0-9A-F]{40})\s", find_identity_output, re.MULTILINE)
    )


def keychain_identities():
    listing = subprocess.run(
        ["security", "find-identity", "-p", "codesigning"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return identity_fingerprints(listing)


def sign_with_entitlements(identity, entitlements_path, bundle):
    signed = subprocess.run(
        [
            "codesign",
            "--force",
            "--sign",
            identity,
            "--entitlements",
            str(entitlements_path),
            "--generate-entitlement-der",
            "--timestamp=none",
            str(bundle),
        ],
        check=False,
    )
    return signed.returncode == 0


def main(app, ipa):
    profiles = installed_profiles()
    if not profiles:
        fail(
            10,
            "No provisioning profile is installed; check the CI's signing setup.",
        )
    if len(profiles) > 1:
        names = ", ".join(profile["Name"] for _, profile in profiles)
        fail(11, f"Expected one provisioning profile, found {len(profiles)}: {names}.")
    profile_path, profile = profiles[0]
    # Device identifiers stay out of the log; only their number is printed.
    print(
        f'Profile "{profile["Name"]}": {profile_kind(profile)}, '
        f"team {profile['TeamIdentifier'][0]}, "
        f"app ID {profile['Entitlements']['application-identifier']}, "
        f"{len(profile.get('ProvisionedDevices', []))} devices, "
        f"expires {profile['ExpirationDate']:%Y-%m-%d}"
    )

    with open(app / "Info.plist", "rb") as f:
        bundle_id = plistlib.load(f)["CFBundleIdentifier"]
    if not covers(profile, bundle_id):
        # Feather signs with such a profile the same way, keeping the app's
        # own bundle ID and the profile's app ID.
        print(
            f"note: the profile's app ID doesn't cover {bundle_id}; "
            "signing with it unchanged, as Feather does."
        )

    identities = keychain_identities()
    identity = next(
        (fp for fp in certificate_fingerprints(profile) if fp in identities), None
    )
    if identity is None:
        fail(
            14,
            "No certificate in the keychain belongs to the profile: the uploaded .p12 and profile don't match.",
        )

    if (app / "Extensions").exists():
        fail(
            15,
            "The app has an Extensions folder; what's in it needs signing before the app.",
        )

    with tempfile.TemporaryDirectory() as work:
        work = pathlib.Path(work)
        payload_app = work / "Payload" / app.name
        shutil.copytree(app, payload_app, symlinks=True)
        shutil.copyfile(profile_path, payload_app / "embedded.mobileprovision")
        entitlements_path = work / "entitlements.plist"
        with open(entitlements_path, "wb") as f:
            plistlib.dump(profile["Entitlements"], f)

        # Embedded frameworks and dylibs (OpenSSL, which zsign uses) are
        # signed first and without entitlements: the app's signature records
        # theirs.
        frameworks = payload_app / "Frameworks"
        nested_code = sorted(frameworks.glob("*.framework")) + sorted(frameworks.glob("*.dylib"))
        for code in nested_code:
            signed = subprocess.run(
                ["codesign", "--force", "--sign", identity, "--timestamp=none", str(code)],
                check=False,
            )
            if signed.returncode != 0:
                fail(16, f"codesign failed to sign {code.name}.")

        # App extensions get the same profile and entitlements, as zsign does,
        # and are signed before the app, whose signature records them.
        for extension in sorted((payload_app / "PlugIns").glob("*.appex")):
            shutil.copyfile(profile_path, extension / "embedded.mobileprovision")
            if not sign_with_entitlements(identity, entitlements_path, extension):
                fail(16, f"codesign failed to sign {extension.name}.")

        if not sign_with_entitlements(identity, entitlements_path, payload_app):
            fail(16, "codesign failed to sign the app.")
        verified = subprocess.run(
            ["codesign", "--verify", "--strict", "--verbose=2", str(payload_app)],
            check=False,
        )
        if verified.returncode != 0:
            fail(17, "The signed app doesn't verify.")

        ipa = ipa.resolve()
        if ipa.exists():
            ipa.unlink()
        subprocess.run(["zip", "-qry", str(ipa), "Payload"], cwd=work, check=True)
    print(f"Signed {bundle_id} and wrote {ipa}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
