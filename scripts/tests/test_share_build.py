"""Tests for scripts/share_build.py, with GitHub and the website faked."""

import io
import json
import pathlib
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import share_build  # noqa: E402

SITE = "https://site.example"
GITHUB = "https://token.actions.example/token?api-version=2.0"


class FakeServices:
    """GitHub's token endpoint and the website's /builds."""

    def __init__(self, fail=None):
        self.fail = fail or {}
        self.calls = []
        self.uploads = {}
        self.recorded = None

    def __call__(self, method, url, headers, data=None, timeout=60):
        self.calls.append((method, url, headers))
        def reply(status, value):
            return status, json.dumps(value).encode()
        if url in self.fail:
            return reply(self.fail[url], {"error": "nope"})
        if url.startswith("https://token.actions.example/"):
            assert headers["Authorization"] == "bearer request-token"
            return reply(200, {"value": "jwt"})
        assert headers["Authorization"] == "Bearer jwt"
        if method == "POST" and url.startswith(f"{SITE}/builds/"):
            name = url.rsplit("/", 1)[1]
            content = data.read()
            assert headers["Content-Length"] == str(len(content))
            self.uploads[name] = content
            return reply(201, {"url": f"{SITE}/builds/{'0' * 32}/{name}", "expires": "2026-11-18T13:00:00.000Z"})
        if method == "POST" and url == f"{SITE}/builds":
            self.recorded = json.loads(data)
            signed = [file for file in self.recorded["files"] if file["signed"]]
            unsigned = [file for file in self.recorded["files"] if not file["signed"]]
            return reply(201, {
                "version": "0.5.1",
                "build": "1042",
                "expires": "2026-11-18T13:00:00.000Z",
                "files": [
                    *({"name": "Atelier.ipa", "url": file["url"], "signed": True, "install": "itms-services://secret",
                       "safari": f"{SITE}/builds/{'0' * 32}/install"} for file in signed),
                    *({"name": "Atelier-unsigned.ipa", "url": file["url"], "signed": False} for file in unsigned),
                ],
                "install": f"{SITE}/install?url=unsigned" if unsigned else None,
            })
        raise AssertionError(f"unexpected {method} {url}")


class ShareBuildTests(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.signed = self.dir / "Atelier.ipa"
        self.unsigned = self.dir / "Atelier-unsigned.ipa"
        self.signed.write_bytes(b"signed IPA")
        self.unsigned.write_bytes(b"unsigned IPA")
        self.summary = self.dir / "summary.md"
        self.env = mock.patch.dict("os.environ", {
            "ACTIONS_ID_TOKEN_REQUEST_URL": GITHUB,
            "ACTIONS_ID_TOKEN_REQUEST_TOKEN": "request-token",
            "GITHUB_STEP_SUMMARY": str(self.summary),
        })
        self.env.start()
        self.addCleanup(self.env.stop)

    def run_share(self, services, *extra):
        out = io.StringIO()
        with mock.patch.object(share_build, "send", services), redirect_stdout(out):
            code = share_build.main(["--site", f"{SITE}/", "--commit", "a" * 40,
                                     "--signed", str(self.signed), "--unsigned", str(self.unsigned), *extra])
        return code, out.getvalue()

    def test_uploads_both_ipas_and_records_the_build(self):
        services = FakeServices()
        code, out = self.run_share(services)
        self.assertEqual(code, 0)
        self.assertEqual(services.uploads, {"Atelier.ipa": b"signed IPA", "Atelier-unsigned.ipa": b"unsigned IPA"})
        self.assertEqual(services.recorded, {"commit": "a" * 40, "files": [
            {"url": f"{SITE}/builds/{'0' * 32}/Atelier.ipa", "signed": True},
            {"url": f"{SITE}/builds/{'0' * 32}/Atelier-unsigned.ipa", "signed": False},
        ]})
        # The token is for the site's origin.
        self.assertEqual(services.calls[0][1], f"{GITHUB}&audience=https%3A%2F%2Fsite.example")

    def test_the_log_and_summary_show_only_the_unsigned_ipas_links(self):
        code, out = self.run_share(FakeServices())
        self.assertEqual(code, 0)
        summary = self.summary.read_text()
        for text in (out, summary):
            self.assertIn(f"{SITE}/builds/{'0' * 32}/Atelier-unsigned.ipa", text)
            self.assertIn(f"{SITE}/install?url=unsigned", text)
            self.assertNotIn(f"{'0' * 32}/Atelier.ipa", text)
            self.assertNotIn("itms-services", text)
            self.assertNotIn(f"{'0' * 32}/install", text)
            self.assertIn("Atelier 0.5.1 (1042)", text)

    def test_a_missing_signed_ipa_is_left_out(self):
        self.signed.unlink()
        services = FakeServices()
        code, _ = self.run_share(services)
        self.assertEqual(code, 0)
        self.assertEqual(list(services.uploads), ["Atelier-unsigned.ipa"])
        self.assertEqual([file["signed"] for file in services.recorded["files"]], [False])

    def test_a_job_without_a_token_shares_nothing(self):
        with mock.patch.dict("os.environ", {"ACTIONS_ID_TOKEN_REQUEST_URL": ""}):
            services = FakeServices()
            code, out = self.run_share(services)
        self.assertEqual(code, 0)
        self.assertEqual(services.calls, [])
        self.assertIn("aren't shared", out)

    def test_a_refusal_is_a_warning_and_exit_code_1(self):
        services = FakeServices(fail={f"{SITE}/builds/Atelier.ipa": 403})
        code, out = self.run_share(services)
        self.assertEqual(code, 1)
        self.assertIn("::warning::The IPAs weren't shared: Uploading Atelier.ipa: HTTP 403: nope", out)
        self.assertFalse(self.summary.exists())

    def test_no_ipa_is_an_error(self):
        self.signed.unlink()
        self.unsigned.unlink()
        code, out = self.run_share(FakeServices())
        self.assertEqual(code, 1)
        self.assertIn("there's no IPA to share", out)

    def test_the_site_is_an_https_origin(self):
        for site in ("http://site.example", "https://site.example/builds", "site.example"):
            with self.assertRaises(share_build.Error, msg=site):
                share_build.site_origin(site)
        self.assertEqual(share_build.site_origin("https://site.example/"), SITE)

    def test_a_token_url_without_a_query_gets_one(self):
        services = FakeServices()
        with mock.patch.dict("os.environ", {"ACTIONS_ID_TOKEN_REQUEST_URL": "https://token.actions.example/token"}), \
                mock.patch.object(share_build, "send", services):
            self.assertEqual(share_build.oidc_token(SITE), "jwt")
        self.assertEqual(services.calls[0][1], "https://token.actions.example/token?audience=https%3A%2F%2Fsite.example")


if __name__ == "__main__":
    unittest.main()
