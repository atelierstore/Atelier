"""Atelier names the device it runs on by its model, ThisDevice.name, so an
iPad reads "this iPad" (#61). These fail when the app's code or its Info.plist
says "iPhone" outright, except where it means an iPhone on any device: a log
line, a check for an iPhone, or one of ALLOWED below."""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCES = [ROOT / "Atelier", ROOT / "Packages" / "AtelierKit" / "Sources"]

# A Swift string literal on one line, escapes and all.
LITERAL = re.compile(r'"(?:[^"\\\n]|\\.)*"')
# Lines that only write to a log, which stays in the developer's words.
LOG = re.compile(r"\b(note|say|log|log\.append)\(|\.log\(")
# Checks for an iPhone, such as Open Spaces', which only an iPhone has.
CHECK = re.compile(r'ThisDevice\.name\s*[!=]=\s*"iPhone"')

# File, and the text on the line that says iPhone on purpose.
ALLOWED = [
    # The device name itself.
    ("Packages/AtelierKit/Sources/InstallKit/ThisDevice.swift", '"iPhone"'),
    # Browse's switch between a source's iPhone and iPad screenshots.
    ("Atelier/Sources/Browse/AppDetailView.swift", 'Text("iPhone").tag(Device.iphone)'),
    # Open Spaces, which only shows on an iPhone.
    ("Atelier/Sources/HomeScreen/YourGapsView.swift", "as on your iPhone"),
    # Apple's name for its own signer, as codesign reports it.
    ("Packages/AtelierKit/Sources/InstallKit/InstalledAppRecord.swift", "Apple iPhone OS Application Signing"),
]


def code(line):
    """The line without its // comment, and the string literals before it."""
    literals = list(LITERAL.finditer(line))
    for found in re.finditer(r"//", line):
        if not any(m.start() <= found.start() < m.end() for m in literals):
            line = line[: found.start()]
            break
    return line, [m.group() for m in LITERAL.finditer(line)]


class DeviceWordingTests(unittest.TestCase):
    def test_app_strings_name_the_device_by_its_model(self):
        found = []
        for folder in SOURCES:
            for path in sorted(folder.rglob("*.swift")):
                name = path.relative_to(ROOT).as_posix()
                allowed = [text for file, text in ALLOWED if file == name]
                for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                    text, literals = code(line)
                    if not any("iPhone" in literal for literal in literals):
                        continue
                    if LOG.search(text) or CHECK.search(text) or any(a in text for a in allowed):
                        continue
                    found.append(f"{name}:{number}: {line.strip()}")
        self.assertEqual(
            found, [],
            "Say this \\(ThisDevice.name) rather than this iPhone, so an iPad reads iPad, "
            "or add the line to ALLOWED if it means an iPhone on any device.",
        )

    def test_usage_descriptions_have_an_ipad_copy(self):
        # iOS shows these in its own alerts, which can't read ThisDevice.name,
        # so each one that says iPhone needs a ~ipad copy that says iPad.
        plist = (ROOT / "project.yml").read_text(encoding="utf-8")
        keys = dict(re.findall(r"^\s*(NS\w+UsageDescription(?:~ipad)?):\s*(.+)$", plist, re.M))
        for key, text in keys.items():
            if key.endswith("~ipad") or "iPhone" not in text:
                continue
            with self.subTest(key=key):
                self.assertEqual(keys.get(key + "~ipad"), text.replace("iPhone", "iPad"))


if __name__ == "__main__":
    unittest.main()
