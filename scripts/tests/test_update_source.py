"""Tests for scripts/update_source.py. Run: python3 -m unittest discover scripts/tests"""

import contextlib
import hashlib
import io
import json
import pathlib
import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile
import zlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import update_source  # noqa: E402

TEMPLATE = json.loads(update_source.TEMPLATE.read_text())
SCREENSHOTS_URL = "https://example.com/screenshots/"


def make_ipa(directory, version="0.1.0", build="7", bundle_id="com.atelier.app"):
    path = pathlib.Path(directory) / f"Atelier-{version}-{build}.ipa"
    info = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
        "MinimumOSVersion": "17.0",
        "NSCameraUsageDescription": "Scans QR codes.",
        "NSLocalNetworkUsageDescription": "Pairs with this iPhone.",
        "UIBackgroundModes": ["fetch"],
    }
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("Payload/Atelier.app/Info.plist", plistlib.dumps(info))
        archive.writestr("Payload/Atelier.app/Atelier", b"binary")
        archive.writestr("Payload/Atelier.app/PlugIns/Widget.appex/Info.plist", plistlib.dumps({"CFBundleIdentifier": "x"}))
    return path


def make_png(path, width, height, shade=0):
    """A PNG of one grey."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = (b"\0" + bytes([shade]) * width * 3) * height
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
    return path


class UpdateSourceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def test_first_release(self):
        ipa = make_ipa(self.directory.name)
        source = update_source.update(TEMPLATE, None, ipa, "0.1.0", "https://example.com/a.ipa", "Notes\n", "2026-10-22T12:00:00Z")
        app = source["apps"][0]
        self.assertEqual(source["name"], "Atelier")
        self.assertEqual(app["versions"], [{
            "version": "0.1.0",
            "buildVersion": "7",
            "date": "2026-10-22T12:00:00Z",
            "localizedDescription": "Notes",
            "downloadURL": "https://example.com/a.ipa",
            "size": ipa.stat().st_size,
            "sha256": hashlib.sha256(ipa.read_bytes()).hexdigest(),
            "minOSVersion": "17.0",
        }])
        self.assertEqual(app["appPermissions"]["privacy"], {
            "NSCameraUsageDescription": "Scans QR codes.",
            "NSLocalNetworkUsageDescription": "Pairs with this iPhone.",
        })
        self.assertEqual(TEMPLATE["apps"][0]["versions"], [], "the template must not change")

    def test_keeps_earlier_versions_newest_first(self):
        first = update_source.update(TEMPLATE, None, make_ipa(self.directory.name, "0.1.0", "1"), "0.1.0", "https://example.com/1.ipa")
        second = update_source.update(TEMPLATE, first, make_ipa(self.directory.name, "0.2.0", "2"), "0.2.0", "https://example.com/2.ipa")
        self.assertEqual([v["version"] for v in second["apps"][0]["versions"]], ["0.2.0", "0.1.0"])

    def test_same_version_and_build_replaces_its_entry(self):
        ipa = make_ipa(self.directory.name)
        first = update_source.update(TEMPLATE, None, ipa, "0.1.0", "https://example.com/old.ipa")
        again = update_source.update(TEMPLATE, first, ipa, "0.1.0", "https://example.com/new.ipa")
        self.assertEqual([v["downloadURL"] for v in again["apps"][0]["versions"]], ["https://example.com/new.ipa"])

    def test_template_fields_win_over_published_ones(self):
        published = json.loads(json.dumps(TEMPLATE))
        published["subtitle"] = "Old subtitle"
        source = update_source.update(TEMPLATE, published, make_ipa(self.directory.name), "0.1.0", "https://example.com/a.ipa")
        self.assertEqual(source["subtitle"], TEMPLATE["subtitle"])

    def test_prerelease_tag_lists_the_ipas_version_shown_with_its_suffix(self):
        ipa = make_ipa(self.directory.name, "0.1.0")
        source = update_source.update(TEMPLATE, None, ipa, "0.1.0-alpha", "https://example.com/a.ipa")
        app = source["apps"][0]
        self.assertEqual((app["versions"][0]["version"], app["versions"][0]["marketingVersion"]), ("0.1.0", "0.1.0-alpha"))
        self.assertEqual(app["versions"][0]["localizedDescription"], "Atelier 0.1.0-alpha.")
        self.assertTrue(app["beta"])
        final = update_source.update(TEMPLATE, source, make_ipa(self.directory.name, "0.1.0", "8"), "0.1.0", "https://example.com/b.ipa")
        self.assertNotIn("beta", final["apps"][0])
        self.assertNotIn("marketingVersion", final["apps"][0]["versions"][0])
        self.assertEqual(len(final["apps"][0]["versions"]), 2)

    def test_notes_are_their_first_paragraph_as_plain_text(self):
        notes = (
            "<!-- draft -->\r\n## Atelier 0.1.0\r\n\r\n"
            "The **first** release of _Atelier_: see [the guide](https://example.com)\r\n"
            "and `docs/install.md`. Keeps snake_case and 2*3*4.\r\n\r\n"
            "## Highlights\r\n\r\n- **One-tap installs.**\r\n"
        )
        self.assertEqual(
            update_source.summary(notes),
            "The first release of Atelier: see the guide and docs/install.md. Keeps snake_case and 2*3*4.",
        )
        self.assertIsNone(update_source.summary("## Only a heading\n\n"))
        source = update_source.update(TEMPLATE, None, make_ipa(self.directory.name), "0.1.0", "https://example.com/a.ipa", "## Title\n")
        self.assertEqual(source["apps"][0]["versions"][0]["localizedDescription"], "Atelier 0.1.0.")

    def test_a_news_item_for_each_release(self):
        first = update_source.update(TEMPLATE, None, make_ipa(self.directory.name, "0.1.0", "1"), "0.1.0-alpha",
                                     "https://example.com/1.ipa", "The first one.\n", "2026-10-22T12:00:00Z")
        second = update_source.update(TEMPLATE, first, make_ipa(self.directory.name, "0.2.0", "2"), "0.2.0-alpha",
                                      "https://example.com/2.ipa", "## 0.2.0\n\nUpdates.\n", "2026-10-27T12:00:00Z")
        self.assertEqual(second["news"], [
            {
                "identifier": "release-0.2.0-alpha",
                "title": "Atelier 0.2.0-alpha is out",
                "caption": "Updates.",
                "date": "2026-10-27T12:00:00Z",
                "tintColor": TEMPLATE["apps"][0]["tintColor"],
                "appID": "com.atelier.app",
            },
            {
                "identifier": "release-0.1.0-alpha",
                "title": "Atelier 0.1.0-alpha is out",
                "caption": "The first one.",
                "date": "2026-10-22T12:00:00Z",
                "tintColor": TEMPLATE["apps"][0]["tintColor"],
                "appID": "com.atelier.app",
            },
        ])
        self.assertEqual(TEMPLATE["news"], [], "the template must not change")

    def test_a_release_published_again_keeps_one_news_item(self):
        first = update_source.update(TEMPLATE, None, make_ipa(self.directory.name, "0.1.0", "1"), "0.1.0",
                                     "https://example.com/1.ipa", "Old.\n")
        again = update_source.update(TEMPLATE, first, make_ipa(self.directory.name, "0.1.0", "2"), "0.1.0",
                                     "https://example.com/2.ipa", "New.\n")
        self.assertEqual(len(again["apps"][0]["versions"]), 2)
        self.assertEqual([(item["identifier"], item["caption"]) for item in again["news"]], [("release-0.1.0", "New.")])

    def test_the_templates_news_goes_after_the_releases_and_replaces_one(self):
        template = json.loads(json.dumps(TEMPLATE))
        del template["apps"][0]["tintColor"]
        template["news"] = [
            {"identifier": "welcome", "title": "Welcome", "caption": "Hi.", "date": "2026-10-01"},
            {"identifier": "release-0.1.0", "title": "Atelier 0.1.0", "caption": "Our own words.", "date": "2026-10-22"},
        ]
        source = update_source.update(template, None, make_ipa(self.directory.name), "0.1.0", "https://example.com/a.ipa")
        self.assertEqual(source["news"], template["news"])
        source = update_source.update(template, None, make_ipa(self.directory.name, "0.2.0"), "0.2.0", "https://example.com/b.ipa")
        self.assertEqual([item["identifier"] for item in source["news"]], ["release-0.2.0", "welcome", "release-0.1.0"])
        self.assertNotIn("tintColor", source["news"][0])

    def test_refuses_a_version_the_ipa_disagrees_with(self):
        with self.assertRaisesRegex(update_source.Error, "version 0.1.0, not 0.2.0"):
            update_source.update(TEMPLATE, None, make_ipa(self.directory.name), "0.2.0", "https://example.com/a.ipa")

    def test_refuses_an_unknown_bundle_id(self):
        ipa = make_ipa(self.directory.name, bundle_id="com.example.other")
        with self.assertRaisesRegex(update_source.Error, "no app with bundle ID"):
            update_source.update(TEMPLATE, None, ipa, "0.1.0", "https://example.com/a.ipa")

    def test_refuses_plain_http(self):
        with self.assertRaisesRegex(update_source.Error, "isn't https"):
            update_source.update(TEMPLATE, None, make_ipa(self.directory.name), "0.1.0", "http://example.com/a.ipa")

    def screenshots_folder(self):
        folder = pathlib.Path(self.directory.name) / "screenshots"
        folder.mkdir()
        return folder

    def test_screenshots_in_the_order_of_their_names_with_their_sizes(self):
        folder = self.screenshots_folder()
        make_png(folder / "10-settings.png", 393, 852)
        make_png(folder / "2-install.png", 852, 393)
        browse = make_png(folder / "1-browse.png", 393, 852)
        (folder / "README.md").write_text("Not a screenshot.\n")
        screenshots = update_source.screenshots_in(folder, SCREENSHOTS_URL.rstrip("/"))
        self.assertEqual([screenshot["imageURL"].split("?")[0] for screenshot in screenshots],
                         [f"{SCREENSHOTS_URL}{name}" for name in ("1-browse.png", "2-install.png", "10-settings.png")])
        self.assertEqual(screenshots[0]["imageURL"],
                         f"{SCREENSHOTS_URL}1-browse.png?v={hashlib.sha256(browse.read_bytes()).hexdigest()[:8]}")
        self.assertEqual([(screenshot["width"], screenshot["height"]) for screenshot in screenshots],
                         [(393, 852), (852, 393), (393, 852)])

        source = update_source.update(TEMPLATE, None, make_ipa(self.directory.name), "0.1.0", "https://example.com/a.ipa",
                                      screenshots=screenshots)
        app = source["apps"][0]
        self.assertEqual(app["screenshots"], screenshots)
        self.assertEqual(app["screenshotURLs"], [screenshot["imageURL"] for screenshot in screenshots])
        self.assertNotIn("screenshots", TEMPLATE["apps"][0], "the template must not change")

    def test_a_replaced_screenshot_gets_a_new_url(self):
        folder = self.screenshots_folder()
        make_png(folder / "1-browse.png", 393, 852)
        before = update_source.screenshots_in(folder, SCREENSHOTS_URL)[0]["imageURL"]
        make_png(folder / "1-browse.png", 393, 852, shade=255)
        after = update_source.screenshots_in(folder, SCREENSHOTS_URL)[0]["imageURL"]
        self.assertNotEqual(before, after)
        self.assertEqual(before.split("?")[0], after.split("?")[0])

    def test_no_screenshots_without_pngs(self):
        self.assertIsNone(update_source.screenshots_in(pathlib.Path(self.directory.name) / "missing", SCREENSHOTS_URL))
        self.assertIsNone(update_source.screenshots_in(self.screenshots_folder(), SCREENSHOTS_URL))
        app = update_source.update(TEMPLATE, None, make_ipa(self.directory.name), "0.1.0", "https://example.com/a.ipa")["apps"][0]
        self.assertNotIn("screenshots", app)
        self.assertNotIn("screenshotURLs", app)

    def test_refuses_screenshots_it_cant_list(self):
        folder = self.screenshots_folder()
        (folder / "1-browse.png").write_bytes(b"GIF89a")
        with self.assertRaisesRegex(update_source.Error, "isn't a PNG"):
            update_source.screenshots_in(folder, SCREENSHOTS_URL)
        (folder / "1-browse.png").unlink()
        make_png(folder / "1 browse.png", 393, 852)
        with self.assertRaisesRegex(update_source.Error, "only letters, digits"):
            update_source.screenshots_in(folder, SCREENSHOTS_URL)
        with self.assertRaisesRegex(update_source.Error, "isn't https"):
            update_source.screenshots_in(folder, "http://example.com/screenshots/")

    def test_command_line_lists_the_screenshots(self):
        folder = self.screenshots_folder()
        make_png(folder / "1-browse.png", 393, 852)
        ipa = make_ipa(self.directory.name)
        output = pathlib.Path(self.directory.name) / "source.json"
        arguments = ["--ipa", str(ipa), "--version", "0.1.0", "--download-url", "https://example.com/a.ipa",
                     "--output", str(output), "--screenshots", str(folder)]
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            update_source.main(arguments)
        self.assertEqual(update_source.main(arguments + ["--screenshots-url", SCREENSHOTS_URL]), 0)
        app = json.loads(output.read_text())["apps"][0]
        self.assertEqual([(screenshot["width"], screenshot["height"]) for screenshot in app["screenshots"]], [(393, 852)])

    def test_command_line_strips_the_tags_v(self):
        ipa = make_ipa(self.directory.name)
        output = pathlib.Path(self.directory.name) / "source.json"
        code = update_source.main(["--ipa", str(ipa), "--version", "v0.1.0", "--download-url", "https://example.com/a.ipa",
                                   "--published", str(output), "--output", str(output)])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(output.read_text())["apps"][0]["versions"][0]["version"], "0.1.0")


if __name__ == "__main__":
    unittest.main()
