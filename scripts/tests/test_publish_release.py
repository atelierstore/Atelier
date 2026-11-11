"""Tests for scripts/publish_release.py, with GitHub's API faked."""

import base64
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import publish_release  # noqa: E402

REPO = "owner/releases"
API = f"https://api.github.com/repos/{REPO}"


class FakeGitHub:
    def __init__(self, release=None, source=None, tags=()):
        self.release = release
        self.branch = source is not None
        self.files = {"source.json": source} if source is not None else {}
        self.tags = set(tags)
        self.tagged = {}
        self.puts = {}
        self.deleted = []
        self.calls = []

    @property
    def source(self):
        return self.files.get("source.json")

    def __call__(self, method, url, token, body=None, content_type=None, accept=None):
        self.calls.append((method, url.split("?")[0]))
        def reply(status, value=None):
            return status, json.dumps(value).encode() if value is not None else b""
        if url.startswith(f"{API}/releases/tags/"):
            return reply(200, self.release) if self.release else reply(404, {"message": "Not Found"})
        if method == "POST" and url == f"{API}/releases":
            self.created = body
            self.release = {"id": 1, "html_url": "https://github.com/x", "assets": []}
            return reply(201, self.release)
        if method == "DELETE" and url.startswith(f"{API}/releases/assets/"):
            return reply(204)
        if method == "POST" and "/releases/1/assets" in url:
            return reply(201, {"browser_download_url": f"https://github.com/{REPO}/releases/download/v0.1.0/Atelier-0.1.0.ipa"})
        if url == f"{API}/git/ref/heads/source":
            return reply(200, {}) if self.branch else reply(404, {"message": "Not Found"})
        if method == "POST" and url == f"{API}/git/trees":
            return reply(201, {"sha": "tree"})
        if method == "POST" and url == f"{API}/git/commits":
            self.root_commit = body
            return reply(201, {"sha": "commit"})
        if url.startswith(f"{API}/git/ref/tags/"):
            return reply(200, {}) if url.removeprefix(f"{API}/git/ref/tags/") in self.tags else reply(404, {"message": "Not Found"})
        if method == "POST" and url == f"{API}/git/refs":
            if body["ref"].startswith("refs/tags/"):
                tag = body["ref"].removeprefix("refs/tags/")
                self.tags.add(tag)
                self.tagged[tag] = body["sha"]
            else:
                self.branch = True
            return reply(201, {})
        if url.startswith(f"{API}/contents/"):
            path, _, query = url.removeprefix(f"{API}/contents/").partition("?")
            if method == "GET":
                assert query == "ref=source", query
                listed = [{"name": name.removeprefix(f"{path}/"), "type": "file", "sha": publish_release.blob_sha(content)}
                          for name, content in self.files.items() if name.startswith(f"{path}/")]
                if self.branch and listed:
                    return reply(200, listed)
                if not self.branch or path not in self.files:
                    return reply(404, {"message": "Not Found"})
                return reply(200, {"content": base64.b64encode(self.files[path]).decode(), "sha": "abc"})
            assert self.branch and body["branch"] == "source", body
            if method == "DELETE":
                assert body["sha"] == publish_release.blob_sha(self.files.pop(path)), body
                self.deleted.append(path)
                return reply(200, {})
            self.files[path] = base64.b64decode(body["content"])
            self.puts[path] = body.get("sha")
            return reply(200, {})
        return reply(500, {"unexpected": url})


class PublishReleaseTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.dir = pathlib.Path(directory.name)
        self.ipa = self.dir / "Atelier-0.1.0.ipa"
        self.ipa.write_bytes(b"ipa")
        self.source = self.dir / "source.json"
        self.source.write_text('{"name": "Atelier"}\n')
        patcher = mock.patch.dict("os.environ", {"GITHUB_RELEASES_TOKEN": "t"})
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_publish(self, github, *extra):
        with mock.patch.object(publish_release, "request", github), mock.patch("builtins.print"):
            return publish_release.main(["publish", "--repo", REPO, "--tag", "v0.1.0",
                                         "--ipa", str(self.ipa), "--source", str(self.source), *extra])

    def test_first_release_uploads_the_ipa_before_writing_the_source(self):
        github = FakeGitHub()
        self.assertEqual(self.run_publish(github), 0)
        methods = [call[0] for call in github.calls]
        self.assertLess(methods.index("POST", 2), methods.index("PUT"))
        self.assertEqual(github.source, self.source.read_bytes())
        self.assertEqual(github.puts, {"source.json": None})
        self.assertEqual(github.root_commit["parents"], [], "the source branch shares no history with main")

    def test_rerun_reuses_the_release_and_replaces_the_ipa(self):
        github = FakeGitHub(
            release={"id": 1, "html_url": "https://github.com/x", "assets": [{"id": 9, "name": "Atelier-0.1.0.ipa"}]},
            source=b"{}",
        )
        self.assertEqual(self.run_publish(github), 0)
        self.assertIn(("DELETE", f"{API}/releases/assets/9"), github.calls)
        self.assertNotIn(("POST", f"{API}/releases"), github.calls)
        self.assertNotIn(("POST", f"{API}/git/refs"), github.calls)
        self.assertEqual(github.puts, {"source.json": "abc"})

    def test_icon_is_committed_only_when_it_changed(self):
        icon = self.dir / "icon.png"
        icon.write_bytes(b"png")
        github = FakeGitHub()
        self.assertEqual(self.run_publish(github, "--icon", str(icon)), 0)
        self.assertEqual(github.files["icon.png"], b"png")
        github.puts.clear()
        self.assertEqual(self.run_publish(github, "--icon", str(icon)), 0)
        self.assertNotIn("icon.png", github.puts)

    def test_screenshots_go_up_before_the_source_and_the_ones_it_dropped_after_it(self):
        github = FakeGitHub(source=b"{}")
        github.files.update({
            "screenshots/1-browse.png": b"browse",
            "screenshots/2-app.png": b"old app",
            "screenshots/3-library.png": b"library",
        })
        folder = self.dir / "screenshots"
        folder.mkdir()
        (folder / "1-browse.png").write_bytes(b"browse")
        (folder / "2-app.png").write_bytes(b"new app")
        (folder / "4-settings.png").write_bytes(b"settings")
        (folder / "README.md").write_text("Not a screenshot.\n")
        self.assertEqual(self.run_publish(github, "--screenshots", str(folder)), 0)

        changed = publish_release.blob_sha(b"old app")
        self.assertEqual(github.puts, {"screenshots/2-app.png": changed, "screenshots/4-settings.png": None, "source.json": "abc"})
        self.assertEqual(github.deleted, ["screenshots/3-library.png"])
        self.assertEqual({path: content for path, content in github.files.items() if path.startswith("screenshots/")}, {
            "screenshots/1-browse.png": b"browse",
            "screenshots/2-app.png": b"new app",
            "screenshots/4-settings.png": b"settings",
        })
        writes = [call for call in github.calls if call[0] in ("PUT", "DELETE")]
        self.assertEqual(writes, [
            ("PUT", f"{API}/contents/screenshots/2-app.png"),
            ("PUT", f"{API}/contents/screenshots/4-settings.png"),
            ("PUT", f"{API}/contents/source.json"),
            ("DELETE", f"{API}/contents/screenshots/3-library.png"),
        ], "the source never lists a screenshot that isn't there")

    def test_blob_sha_is_gits(self):
        # echo hello | git hash-object --stdin
        self.assertEqual(publish_release.blob_sha(b"hello\n"), "ce013625030ba8dba906f756967f9e9ca394464a")

    def test_prerelease_tags_make_prereleases(self):
        github = FakeGitHub()
        with mock.patch.object(publish_release, "request", github), mock.patch("builtins.print"):
            publish_release.main(["publish", "--repo", REPO, "--tag", "v0.1.0-alpha",
                                  "--ipa", str(self.ipa), "--source", str(self.source)])
        self.assertTrue(github.created["prerelease"])
        github = FakeGitHub()
        self.run_publish(github)
        self.assertFalse(github.created["prerelease"])

    def test_release_notes_come_from_a_release_made_on_the_site(self):
        output = self.dir / "notes.md"
        github = FakeGitHub(release={"id": 1, "html_url": "x", "assets": [], "body": "## Highlights\r\n- One\r\n"})
        with mock.patch.object(publish_release, "request", github):
            self.assertEqual(publish_release.main(["release-notes", "--repo", REPO, "--tag", "v0.1.0", "--output", str(output)]), 0)
        self.assertEqual(output.read_text(), "## Highlights\n- One\n")
        output.unlink()
        with mock.patch.object(publish_release, "request", FakeGitHub()):
            self.assertEqual(publish_release.main(["release-notes", "--repo", REPO, "--tag", "v0.1.0", "--output", str(output)]), 0)
        self.assertFalse(output.exists())

    def test_fetch_source_writes_nothing_for_the_first_release(self):
        output = self.dir / "published.json"
        with mock.patch.object(publish_release, "request", FakeGitHub()), mock.patch("builtins.print"):
            self.assertEqual(publish_release.main(["fetch-source", "--repo", REPO, "--output", str(output)]), 0)
        self.assertFalse(output.exists())

    def test_api_errors_fail_with_the_status(self):
        def failing(*args, **kwargs):
            return 403, b'{"message": "Resource not accessible"}'
        with mock.patch.object(publish_release, "request", failing), mock.patch("sys.stderr") as stderr:
            self.assertEqual(publish_release.main(["fetch-source", "--repo", REPO, "--output", "x"]), 1)
        self.assertIn("HTTP 403", "".join(call.args[0] for call in stderr.write.call_args_list))

    def write_notes(self, *names):
        notes = self.dir / "notes"
        notes.mkdir()
        for name in names:
            (notes / name).write_text("Notes.\n")
        return notes

    def run_tag(self, github, notes, missing=()):
        self.covered = []
        def unmentioned(path, until):
            self.covered.append(until)
            return "v0.1.0-alpha", list(missing)
        with mock.patch.object(publish_release, "request", github), \
                mock.patch.object(publish_release, "changed_in", lambda path: f"commit changing {path.name}"), \
                mock.patch.object(publish_release, "unmentioned", unmentioned), \
                mock.patch("builtins.print"), mock.patch("sys.stderr"):
            return publish_release.main(["tag", "--repo", REPO, "--notes", str(notes)])

    def test_tag_tags_the_commit_that_last_changed_the_new_releases_notes(self):
        github = FakeGitHub(tags={"v0.1.0-alpha"})
        notes = self.write_notes("v0.1.0-alpha.md", "v0.2.0-alpha.md", "README.md")
        self.assertEqual(self.run_tag(github, notes), 0)
        self.assertEqual(github.tagged, {"v0.2.0-alpha": "commit changing v0.2.0-alpha.md"})
        self.assertEqual(self.covered, ["commit changing v0.2.0-alpha.md^"], "the notes cover main before them")

    def test_tag_gives_github_actions_the_tag_it_created(self):
        outputs = self.dir / "outputs"
        github = FakeGitHub(tags={"v0.1.0-alpha"})
        notes = self.write_notes("v0.1.0-alpha.md")
        with mock.patch.dict("os.environ", {"GITHUB_OUTPUT": str(outputs)}):
            self.assertEqual(self.run_tag(github, notes), 0)
            self.assertFalse(outputs.exists(), "nothing to release, so no tag")
            (notes / "v0.2.0-alpha.md").write_text("Notes.\n")
            self.assertEqual(self.run_tag(github, notes), 0)
        self.assertEqual(outputs.read_text(), "tag=v0.2.0-alpha\n")

    def test_tag_refuses_notes_that_miss_a_pull_request(self):
        github = FakeGitHub(tags={"v0.1.0-alpha"})
        self.assertEqual(self.run_tag(github, self.write_notes("v0.2.0-alpha.md"), missing=[101]), 1)
        self.assertEqual(github.tagged, {})

    def test_tag_does_nothing_when_every_release_has_its_tag(self):
        github = FakeGitHub(tags={"v0.1.0-alpha"})
        self.assertEqual(self.run_tag(github, self.write_notes("v0.1.0-alpha.md")), 0)
        self.assertEqual(github.tagged, {})

    def test_tag_refuses_two_new_releases_at_once(self):
        github = FakeGitHub()
        self.assertEqual(self.run_tag(github, self.write_notes("v0.2.0.md", "v0.3.0.md")), 1)
        self.assertEqual(github.tagged, {})

    def test_next_releases_notes_never_start_it(self):
        github = FakeGitHub(tags={"v0.1.0-alpha"})
        self.assertEqual(self.run_tag(github, self.write_notes("v0.1.0-alpha.md", "next.md")), 0)
        self.assertEqual(github.tagged, {})

    def test_tag_refuses_notes_not_named_after_a_tag(self):
        github = FakeGitHub()
        self.assertEqual(self.run_tag(github, self.write_notes("v0.2.0alpha.md")), 1)
        self.assertEqual(github.tagged, {})

    def test_needs_the_token(self):
        with mock.patch.dict("os.environ", {}, clear=True), mock.patch("sys.stderr"):
            self.assertEqual(publish_release.main(["fetch-source", "--repo", REPO, "--output", "x"]), 2)


class Repo:
    """A git repo whose pull requests merge into main the way GitHub merges
    them."""

    def __init__(self, directory):
        self.dir = pathlib.Path(directory)
        self.git("init", "-q", "-b", "main")
        self.commit("README.md", "Atelier")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.dir), "-c", "user.name=Atelier", "-c", "user.email=atelier@example.com",
                               "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", *args],
                              check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, path, text):
        (self.dir / path).parent.mkdir(parents=True, exist_ok=True)
        (self.dir / path).write_text(f"{text}\n")
        self.git("add", path)
        self.git("commit", "-q", "-m", text)

    def branch(self, name, path, text):
        """A pull request's branch from main that writes text to path."""
        self.git("checkout", "-q", "-b", name, "main")
        self.commit(path, text)
        self.git("checkout", "-q", "main")

    def merge(self, number, branch):
        self.git("merge", "-q", "--no-ff", "-m", f"Merge pull request #{number} from owner/{branch}", branch)
        return self.git("rev-parse", "HEAD")

    def pull_request(self, number, path, text):
        self.branch(f"pr-{number}", path, text)
        return self.merge(number, f"pr-{number}")


class ReleaseNotesTests(unittest.TestCase):
    """The checks on release notes, with a real git history: the release
    v0.1.0, then pull requests #5 and #6 merged into main."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.repo = Repo(directory.name)
        self.repo.git("tag", "v0.1.0")
        self.repo.pull_request(5, "app.txt", "Updates")
        self.repo.pull_request(6, "ci.txt", "Build numbers")
        self.notes_dir = self.repo.dir / "release/notes"
        self.notes = self.notes_dir / "v0.2.0.md"

    def test_the_notes_last_changed_in_their_merge_on_main(self):
        self.repo.branch("release", "release/notes/v0.2.0.md", "Updates (#5), build numbers (#6).")
        self.repo.pull_request(7, "other.txt", "Merged before them")
        merge = self.repo.merge(8, "release")
        self.repo.pull_request(9, "later.txt", "Merged after them")
        self.assertEqual(publish_release.changed_in(self.notes), merge)
        fixed = self.repo.pull_request(10, "release/notes/v0.2.0.md", "Updates (#5), build numbers (#6), other (#7).")
        self.assertEqual(publish_release.changed_in(self.notes), fixed)

    def test_notes_mention_every_pull_request_merged_since_the_last_release(self):
        self.notes_dir.mkdir(parents=True)
        self.notes.write_text("Updates (#5). Not #60.\n")
        self.assertEqual(publish_release.unmentioned(self.notes, "main"), ("v0.1.0", [6]))
        self.notes.write_text("Updates (#5).\n\nBuild numbers (#6).\n")
        self.assertEqual(publish_release.unmentioned(self.notes, "main"), ("v0.1.0", []))

    def test_pull_requests_that_changed_the_notes_needn_t_mention_themselves(self):
        self.repo.pull_request(7, "release/notes/v0.2.0.md", "Updates (#5), build numbers (#6).")
        self.repo.pull_request(8, "more.txt", "Merged after the notes")
        fixed = self.repo.pull_request(9, "release/notes/v0.2.0.md", "Updates (#5) and build numbers (#6).")
        self.assertEqual(publish_release.unmentioned(self.notes, f"{fixed}^"), ("v0.1.0", [8]))

    def test_nothing_to_check_without_a_release_before(self):
        self.repo.git("tag", "-d", "v0.1.0")
        self.notes_dir.mkdir(parents=True)
        self.notes.write_text("The first release.\n")
        self.assertEqual(publish_release.unmentioned(self.notes, "main"), (None, []))

    def check_notes(self, pr=None):
        args = ["check-notes", "--notes", str(self.notes_dir), "--main", "main", *(["--pr", str(pr)] if pr else [])]
        with mock.patch.dict("os.environ"), mock.patch("builtins.print"), mock.patch("sys.stderr"):
            os.environ.pop("GITHUB_RELEASES_TOKEN", None)
            return publish_release.main(args)

    def missing(self, pr):
        """What check-notes finds next.md is missing on this branch, as pull
        request `pr`."""
        [(path, since, missing)] = publish_release.check_notes(self.notes_dir, "main", pr)
        self.assertEqual((path.name, since), ("next.md", "v0.1.0"))
        return missing

    def test_check_notes_checks_the_notes_a_branch_adds_against_main(self):
        self.repo.git("checkout", "-q", "-b", "release")
        self.repo.commit("release/notes/v0.2.0.md", "Updates (#5), build numbers (#6).")
        self.assertEqual(self.check_notes(), 0)
        self.repo.git("checkout", "-q", "main")
        self.repo.pull_request(7, "more.txt", "Merged after the notes")
        self.repo.git("checkout", "-q", "release")
        self.assertEqual(self.check_notes(), 1)
        self.repo.git("merge", "-q", "--no-edit", "main")
        self.repo.commit("release/notes/v0.2.0.md", "Updates (#5), build numbers (#6), more (#7).")
        self.assertEqual(self.check_notes(), 0)

    def test_check_notes_leaves_out_other_branches_and_released_notes(self):
        self.repo.git("checkout", "-q", "-b", "feature")
        self.repo.commit("app.txt", "Something else")
        self.assertEqual(self.check_notes(), 0, "no notes at all")
        self.repo.commit("release/notes/v0.1.0.md", "The release before, fixed.")
        self.assertEqual(self.check_notes(), 0, "notes of a release that has its tag")

    def test_next_notes_mention_the_pull_request_and_every_one_merged_since_the_last_release(self):
        self.repo.commit("release/notes/v0.1.0.md", "The first release.")
        self.repo.git("checkout", "-q", "-b", "pr-7")
        self.repo.commit("feature.txt", "A feature")
        self.assertEqual(self.missing(7), [5, 6, 7], "no next.md yet")
        self.repo.commit("release/notes/next.md", "- A feature (#7).")
        self.assertEqual(self.missing(7), [5, 6])
        self.assertEqual(self.check_notes(pr=7), 1)
        self.repo.commit("release/notes/next.md", "- Updates (#5).\n- Build numbers (#6).")
        self.assertEqual(self.missing(7), [7])
        self.assertEqual(self.check_notes(pr=7), 1)
        self.repo.commit("release/notes/next.md", "- Updates (#5).\n- Build numbers (#6).\n- A feature (#7).")
        self.assertEqual(self.check_notes(pr=7), 0)

    def test_a_pull_request_that_only_changes_release_notes_needn_t_mention_itself(self):
        self.repo.git("checkout", "-q", "-b", "pr-7")
        self.repo.commit("release/notes/next.md", "- Updates (#5).\n- Build numbers (#6).")
        self.assertEqual(self.missing(7), [])
        self.assertEqual(self.check_notes(pr=7), 0)

    def test_without_the_pull_request_next_notes_are_checked_once_they_re_there(self):
        self.repo.git("checkout", "-q", "-b", "feature")
        self.repo.commit("feature.txt", "A feature")
        self.assertEqual(self.check_notes(), 0, "no next.md")
        self.repo.commit("release/notes/next.md", "- Updates (#5).")
        self.assertEqual(self.check_notes(), 1, "#6 isn't there")

    def test_pull_requests_that_added_their_line_to_next_notes_are_mentioned_in_the_release(self):
        self.repo.pull_request(7, "release/notes/next.md", "- Updates (#5).\n- Build numbers (#6).")
        self.repo.git("checkout", "-q", "-b", "pr-8", "main")
        self.repo.commit("feature.txt", "A feature")
        self.repo.commit("release/notes/next.md", "- Updates (#5).\n- Build numbers (#6).\n- A feature (#8).")
        self.repo.git("checkout", "-q", "main")
        self.repo.merge(8, "pr-8")
        self.assertEqual(publish_release.unmentioned(self.notes_dir / "next.md", "main"), ("v0.1.0", []))
        self.notes.write_text("Updates (#5) and build numbers (#6).\n")
        self.assertEqual(publish_release.unmentioned(self.notes, "main"), ("v0.1.0", [8]),
                         "#7 only changed the notes; #8 changed the app too")

    def test_a_release_is_checked_instead_of_next_notes(self):
        self.repo.pull_request(7, "release/notes/next.md", "- Updates (#5).\n- Build numbers (#6).")
        self.repo.git("checkout", "-q", "-b", "release")
        self.repo.git("mv", "release/notes/next.md", "release/notes/v0.2.0.md")
        self.repo.git("commit", "-q", "-m", "Release 0.2.0")
        [(path, since, missing)] = publish_release.check_notes(self.notes_dir, "main", 9)
        self.assertEqual((path.name, since, missing), ("v0.2.0.md", "v0.1.0", []))
        self.assertEqual(self.check_notes(pr=9), 0)


if __name__ == "__main__":
    unittest.main()
