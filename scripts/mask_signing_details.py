#!/usr/bin/env python3
"""Hides a signing certificate's details in a GitHub Actions log: prints an
::add-mask:: command for each detail of a provisioning profile, and of the
certificates it lists, that a public repo's log mustn't show. zsign, codesign
and scripts/sign_ipa.py print some of them while they sign (the team ID, the
certificate's name and ID, the profile's name, which can hold a UDID, and its
App ID); masked, they show as *** for the rest of the job
(.github/workflows/build.yml).

Usage: python3 scripts/mask_signing_details.py <profile.mobileprovision>

Prints nothing and exits with 1 when it can't read the profile or a
certificate in it, so the build stops before anything signs.
"""

import plistlib
import re
import sys

# The certificate subject's attributes that name its holder: commonName
# ("iPhone Developer: Name (ID)"), organizationalUnitName (the team ID),
# organizationName and userId (the certificate's ID).
HOLDER_OIDS = {
    bytes.fromhex("550403"),
    bytes.fromhex("55040b"),
    bytes.fromhex("55040a"),
    bytes.fromhex("0992268993f22c640101"),
}

# DER string types whose bytes aren't UTF-8 (or ASCII, a part of it).
BMP_STRING = 0x1E

# The certificate's ID at the end of its name, "iPhone Developer: Name (A1B2C3D4E5)".
CERTIFICATE_ID = re.compile(r"\(([A-Z0-9]{10})\)")

# Shorter values would mask unrelated text all over the log.
SHORTEST = 4


class Unreadable(Exception):
    pass


def elements(data, start, end):
    """The DER elements in data[start:end], as (tag, start, end) of their contents."""
    found = []
    offset = start
    while offset < end:
        if offset + 2 > end:
            raise Unreadable("a DER element runs past its end")
        tag, length = data[offset], data[offset + 1]
        offset += 2
        if length & 0x80:
            count = length & 0x7F
            if not 1 <= count <= 4 or offset + count > end:
                raise Unreadable("a DER length can't be read")
            length = int.from_bytes(data[offset:offset + count], "big")
            offset += count
        if offset + length > end:
            raise Unreadable("a DER element runs past its end")
        found.append((tag, offset, offset + length))
        offset += length
    return found


def holder(certificate):
    """The values of a DER certificate's subject attributes in HOLDER_OIDS."""
    top = elements(certificate, 0, len(certificate))
    if len(top) != 1:
        raise Unreadable("not one certificate")
    parts = elements(certificate, top[0][1], top[0][2])
    if not parts:
        raise Unreadable("a certificate has no content")
    fields = elements(certificate, parts[0][1], parts[0][2])
    if fields and fields[0][0] == 0xA0:
        fields = fields[1:]
    # serialNumber, signature, issuer, validity, subject.
    if len(fields) < 5:
        raise Unreadable("a certificate has no subject")
    values = []
    for _, set_start, set_end in elements(certificate, fields[4][1], fields[4][2]):
        for _, start, end in elements(certificate, set_start, set_end):
            pair = elements(certificate, start, end)
            if len(pair) != 2 or pair[0][0] != 0x06:
                raise Unreadable("a certificate's subject can't be read")
            if certificate[pair[0][1]:pair[0][2]] in HOLDER_OIDS:
                tag, value_start, value_end = pair[1]
                value = certificate[value_start:value_end]
                values.append(value.decode("utf-16-be" if tag == BMP_STRING else "utf-8", "replace"))
    return values


def profile(data):
    """The property list a provisioning profile signs."""
    start, end = data.find(b"<?xml"), data.find(b"</plist>")
    if start < 0 or end < start:
        raise Unreadable("no property list in it")
    try:
        content = plistlib.loads(data[start:end + len(b"</plist>")])
    except Exception as error:
        raise Unreadable(f"its property list can't be read ({error})")
    if not isinstance(content, dict):
        raise Unreadable("its property list isn't a dictionary")
    return content


def strings(value):
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [item for item in value if isinstance(item, str)]
    return []


def details(content):
    """What of the profile and its certificates the log mustn't show."""
    found = []
    for key in ("TeamName", "TeamIdentifier", "ApplicationIdentifierPrefix", "Name", "AppIDName", "UUID"):
        found += strings(content.get(key))
    for udid in strings(content.get("ProvisionedDevices")):
        found += [udid, udid.lower(), udid.upper()]
    entitlements = content.get("Entitlements")
    if isinstance(entitlements, dict):
        found += strings(entitlements.get("com.apple.developer.team-identifier"))
        for app_id in strings(entitlements.get("application-identifier")):
            # The App ID, and its bundle ID without the team in front.
            found += [app_id, app_id.partition(".")[2]]
    certificates = content.get("DeveloperCertificates")
    if not isinstance(certificates, list) or not certificates:
        raise Unreadable("it lists no certificates")
    for certificate in certificates:
        if not isinstance(certificate, bytes):
            raise Unreadable("a certificate in it isn't data")
        for value in holder(certificate):
            found += [value, *CERTIFICATE_ID.findall(value)]
    masked = []
    for value in found:
        value = value.strip()
        if len(value) >= SHORTEST and "*" not in value and value not in masked:
            masked.append(value)
    return masked


def command(value):
    """The ::add-mask:: workflow command for value, escaped as GitHub's toolkit does."""
    escaped = value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    return f"::add-mask::{escaped}"


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        print("Usage: mask_signing_details.py <profile.mobileprovision>", file=sys.stderr)
        return 2
    try:
        with open(argv[0], "rb") as file:
            masked = details(profile(file.read()))
    except (OSError, Unreadable) as error:
        print(f"The provisioning profile can't be read: {error}", file=sys.stderr)
        return 1
    for value in masked:
        print(command(value))
    return 0


if __name__ == "__main__":
    sys.exit(main())
