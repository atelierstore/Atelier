"""Tests for scripts/mask_signing_details.py, on the throwaway test profiles."""

import contextlib
import io
import pathlib
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import mask_signing_details  # noqa: E402

FIXTURES = pathlib.Path(__file__).resolve().parents[2] / "Packages/AtelierKit/Tests/CertKitTests/Fixtures"


def fixture(name):
    return (FIXTURES / name).read_bytes()


def certificate():
    """The test certificate the development fixture lists, as DER."""
    return mask_signing_details.profile(fixture("development.mobileprovision"))["DeveloperCertificates"][0]


def signed(content):
    """A profile's bytes as a signature wraps them: the property list between other bytes."""
    return b"\x30\x80\x06\x09" + plistlib.dumps(content) + b"\xa0\x82\x01\x00"


class MaskSigningDetailsTests(unittest.TestCase):
    def run_main(self, data):
        with tempfile.NamedTemporaryFile(suffix=".mobileprovision") as file:
            file.write(data)
            file.flush()
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                status = mask_signing_details.main([file.name])
        return status, out.getvalue(), err.getvalue()

    def test_masks_the_team_the_profile_its_devices_and_the_certificate(self):
        status, out, _ = self.run_main(fixture("development.mobileprovision"))
        self.assertEqual(status, 0)
        self.assertEqual(out.splitlines(), [
            "::add-mask::OwnStore Test",
            "::add-mask::TESTTEAM01",
            "::add-mask::OwnStore Test development",
            "::add-mask::89622955-D4A0-4864-8F34-703B3FCA91FE",
            "::add-mask::00008110-000A1B2C3D4E5F60",
            "::add-mask::00008110-000a1b2c3d4e5f60",
            "::add-mask::00008120-0011223344556677",
            "::add-mask::iPhone Distribution: OwnStore Test (TESTTEAM01)",
        ])

    def test_masks_an_app_id_its_bundle_id_and_a_name_holding_a_udid(self):
        content = {
            "Name": "00008130-001A2B3C4D5E6F70QWERTY_dev",
            "TeamIdentifier": ["A1B2C3D4E5"],
            "ProvisionedDevices": ["00008130-001A2B3C4D5E6F70"],
            "Entitlements": {"application-identifier": "A1B2C3D4E5.app.example.signing"},
            "DeveloperCertificates": [certificate()],
        }
        masked = mask_signing_details.details(mask_signing_details.profile(signed(content)))
        for value in ("00008130-001A2B3C4D5E6F70QWERTY_dev", "00008130-001A2B3C4D5E6F70",
                      "00008130-001a2b3c4d5e6f70", "A1B2C3D4E5.app.example.signing", "app.example.signing"):
            self.assertIn(value, masked)

    def test_masks_the_certificate_id_in_its_name(self):
        self.assertEqual(mask_signing_details.CERTIFICATE_ID.findall("iPhone Developer: Created via API (Q1W2E3R4T5)"),
                         ["Q1W2E3R4T5"])

    def test_leaves_out_wildcards_and_short_values(self):
        content = {
            "TeamName": "AB",
            "Entitlements": {"application-identifier": "A1B2C3D4E5.*"},
            "DeveloperCertificates": [certificate()],
        }
        masked = mask_signing_details.details(mask_signing_details.profile(signed(content)))
        self.assertNotIn("AB", masked)
        self.assertFalse([value for value in masked if "*" in value])

    def test_refuses_a_file_that_isnt_a_profile(self):
        status, out, err = self.run_main(fixture("signing.p12"))
        self.assertEqual(status, 1)
        self.assertEqual(out, "")
        self.assertIn("can't be read", err)

    def test_refuses_a_profile_without_certificates(self):
        status, out, _ = self.run_main(signed({"TeamIdentifier": ["A1B2C3D4E5"]}))
        self.assertEqual(status, 1)
        self.assertEqual(out, "")

    def test_refuses_a_certificate_it_cant_read(self):
        status, out, _ = self.run_main(signed({"DeveloperCertificates": [certificate()[:40]]}))
        self.assertEqual(status, 1)
        self.assertEqual(out, "")

    def test_escapes_the_command_as_githubs_toolkit_does(self):
        self.assertEqual(mask_signing_details.command("50% off\r\nnow"), "::add-mask::50%25 off%0D%0Anow")


if __name__ == "__main__":
    unittest.main()
