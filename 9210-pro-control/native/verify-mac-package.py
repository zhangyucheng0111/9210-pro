#!/usr/bin/env python3
"""Verify a Mac release ZIP without launching its application or using Bluetooth."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import unicodedata
import zipfile


NATIVE_DIR = Path(__file__).resolve().parent
APP_NAME = "9210 Pro Control.app"
EXECUTABLE = "9210ProControl"
MINIMUM_SYSTEM = "14.0"
EXPECTED_ARCHES = {"arm64": {"arm64"}, "x86_64": {"x86_64"}, "universal": {"arm64", "x86_64"}}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def command(*args):
    result = subprocess.run(args, capture_output=True, text=True, check=False)
    require(result.returncode == 0, f"{args[0]} failed: {(result.stderr or result.stdout).strip()}")
    return result.stdout, result.stderr


def expected_version():
    source = (NATIVE_DIR / "build.sh").read_text()
    values = []
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        match = re.search(r"<key>" + key + r"</key>\s*<string>([^<]+)</string>", source)
        require(match is not None, f"Cannot read canonical {key} from build.sh")
        values.append(match.group(1))
    return values


def check_zip_members(archive):
    """Reject traversal, special files and case collisions before calling ditto."""
    with zipfile.ZipFile(archive) as zipped:
        entries = zipped.infolist()
        require(entries, "Archive is empty")
        require(len(entries) <= 10000, "Archive has too many members")
        require(sum(item.file_size for item in entries) <= 250 * 1024 * 1024, "Archive exceeds the 250 MiB extraction limit")
        seen = set()
        for item in entries:
            name = item.filename
            parts = name.rstrip("/").split("/")
            require(not name.startswith("/") and "\\" not in name and "\x00" not in name, f"Unsafe ZIP member: {name!r}")
            require(all(part not in ("", ".", "..") for part in parts), f"Unsafe ZIP path: {name!r}")
            require(parts[0] in (archive.stem, "__MACOSX"), f"Unexpected ZIP root: {parts[0]}")
            normalized = unicodedata.normalize("NFC", "/".join(parts)).casefold()
            require(normalized not in seen, f"Duplicate or case-colliding ZIP member: {name}")
            seen.add(normalized)
            mode = item.external_attr >> 16
            require(stat.S_IFMT(mode) in (0, stat.S_IFREG, stat.S_IFDIR), f"ZIP member is a symlink or special file: {name}")
            require(not item.flag_bits & 1, f"Encrypted ZIP member: {name}")
        require(zipped.testzip() is None, "ZIP CRC verification failed")
        return len(entries)


def resource_hashes(directory):
    hashes = {}
    for path in sorted(directory.rglob("*")):
        require(not path.is_symlink(), f"Unexpected resource symlink: {path.name}")
        if path.is_file():
            hashes[path.relative_to(directory).as_posix()] = sha256(path)
    return hashes


def check_layout(release):
    require(release.is_dir(), "Expected release root was not extracted")
    require({p.name for p in release.iterdir()} == {APP_NAME, "README.txt"}, "Release must contain only the app and README.txt")
    readme = release / "README.txt"
    require(readme.is_file() and readme.stat().st_size > 0, "README.txt is missing or empty")
    app = release / APP_NAME
    require({p.name for p in app.iterdir()} == {"Contents"}, "Unexpected entry at app root")
    contents = app / "Contents"
    require({p.name for p in contents.iterdir()} == {"Info.plist", "MacOS", "Resources", "_CodeSignature"}, "Unexpected or missing bundle contents")
    require({p.name for p in (contents / "MacOS").iterdir()} == {EXECUTABLE}, "Unexpected executable/helper payload")
    require({p.name for p in (contents / "_CodeSignature").iterdir()} == {"CodeResources"}, "Unexpected signature payload")
    private_names = {"workspace.json", "bluetooth.json", "runs", "logs", "communication", "manual-actions"}
    for path in release.rglob("*"):
        require(not path.is_symlink(), f"Extracted bundle contains a symlink: {path.name}")
        require(path.name.casefold() not in private_names, f"User data was included: {path.relative_to(release)}")
    executable = contents / "MacOS" / EXECUTABLE
    require(executable.is_file() and os.access(executable, os.X_OK), "Main executable is missing or not executable")
    return app, contents, executable


def version_tuple(value):
    return tuple(int(part) for part in value.split("."))


def inspect_binary(executable, expected_arches):
    architectures = set(command("/usr/bin/lipo", "-archs", str(executable))[0].split())
    require(architectures == expected_arches, f"Architecture mismatch: expected {sorted(expected_arches)}, got {sorted(architectures)}")
    builds = {}
    libraries = {}
    for arch in sorted(architectures):
        load_commands = command("/usr/bin/otool", "-arch", arch, "-l", str(executable))[0]
        build_sections = re.findall(r"\bcmd LC_BUILD_VERSION\b(.*?)(?=\nLoad command |\Z)", load_commands, re.S)
        require(len(build_sections) == 1, f"Missing or ambiguous LC_BUILD_VERSION for {arch}")
        platform = re.search(r"\bplatform\s+(\S+)", build_sections[0])
        minimum = re.search(r"\bminos\s+([\d.]+)", build_sections[0])
        sdk = re.search(r"\bsdk\s+([\d.]+)", build_sections[0])
        require(platform and platform.group(1) in ("1", "MACOS"), f"Unexpected platform for {arch}")
        require(minimum and version_tuple(minimum.group(1)) == version_tuple(MINIMUM_SYSTEM), f"Deployment target is not {MINIMUM_SYSTEM} for {arch}")
        rpaths = re.findall(r"\bcmd LC_RPATH\b.*?\n\s*path (\S+) \(offset", load_commands, re.S)
        require(all(path in ("/usr/lib/swift", "/usr/lib") for path in rpaths), f"Non-system runtime search path for {arch}: {rpaths}")
        linked = command("/usr/bin/otool", "-arch", arch, "-L", str(executable))[0]
        dependencies = re.findall(r"^\s+(.+?)\s+\(compatibility version", linked, re.M)
        require(dependencies, f"No linked libraries found for {arch}")
        require(all(path.startswith(("/System/Library/", "/usr/lib/")) for path in dependencies), f"Non-system library dependency for {arch}: {dependencies}")
        builds[arch] = {"minimum_macos": minimum.group(1), "sdk": sdk.group(1) if sdk else None, "runtime_search_paths": rpaths}
        libraries[arch] = dependencies
    return sorted(architectures), builds, libraries


def verify(archive, arch):
    require(archive.is_file() and archive.suffix == ".zip", "Input must be an existing .zip")
    digest = sha256(archive)
    sidecar = archive.with_suffix(".sha256")
    require(sidecar.is_file(), f"Missing checksum file: {sidecar.name}")
    checksum = re.fullmatch(r"([0-9a-fA-F]{64})\s+\*?([^\r\n]+)\s*", sidecar.read_text().strip())
    require(checksum is not None and checksum.group(2) == archive.name, "Checksum sidecar must name this ZIP exactly")
    require(checksum.group(1).lower() == digest, "ZIP SHA-256 does not match its sidecar")
    member_count = check_zip_members(archive)
    version, build = expected_version()
    require(archive.stem.startswith(f"9210-Pro-Control-{version}-Mac"), f"Archive filename does not match current source version {version}")
    with tempfile.TemporaryDirectory(prefix="9210-package-verification-") as temporary:
        destination = Path(temporary)
        command("/usr/bin/ditto", "-x", "-k", str(archive), str(destination))
        app, contents, executable = check_layout(destination / archive.stem)
        with (contents / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        require(info.get("CFBundleIdentifier") == "local.lab.pipetter9210.maccontrol", "Bundle identifier mismatch")
        require(info.get("CFBundleShortVersionString") == version and info.get("CFBundleVersion") == build, "Bundle version/build does not match current build.sh")
        require(info.get("CFBundlePackageType") == "APPL" and info.get("CFBundleExecutable") == EXECUTABLE, "Bundle executable metadata mismatch")
        require(info.get("LSMinimumSystemVersion") == MINIMUM_SYSTEM, "Info.plist minimum macOS mismatch")
        require(bool(info.get("NSBluetoothAlwaysUsageDescription")), "Bluetooth permission explanation is missing")
        command("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
        signing = command("/usr/bin/codesign", "-d", "--verbose=4", str(app))
        metadata = "\n".join(signing)
        adhoc = "Signature=adhoc" in metadata
        architectures, builds, libraries = inspect_binary(executable, EXPECTED_ARCHES[arch])
        expected_resources = resource_hashes(NATIVE_DIR / "Resources")
        actual_resources = resource_hashes(contents / "Resources")
        require(expected_resources == actual_resources, "Bundled resources do not exactly match native/Resources")
        return {
            "state": "passed",
            "archive": str(archive),
            "bytes": archive.stat().st_size,
            "sha256": digest,
            "checksum_sidecar": "matched",
            "zip_members": member_count,
            "version": version,
            "build": build,
            "architectures": architectures,
            "minimum_macos": MINIMUM_SYSTEM,
            "binary_build_versions": builds,
            "linked_libraries": libraries,
            "code_signature": "adhoc; deep/strict valid after extraction" if adhoc else "deep/strict valid after extraction",
            "notarized": False if adhoc else None,
            "notarization_evidence": "ad-hoc signature; no Developer ID identity" if adhoc else "not checked by this verifier",
            "resource_files": len(actual_resources),
            "resources_match_source": True,
            "current_custom_workspace_included": False,
            "bluetooth_preference_included": False,
            "runtime_hardware_access_attempted": False,
            "runtime_launch_tested": False,
            "limitations": ["Static archive verification does not test Intel hardware or macOS 14/15 runtime compatibility."],
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--arch", required=True, choices=EXPECTED_ARCHES)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    archive = args.archive.expanduser().resolve()
    try:
        report = verify(archive, args.arch)
        status = 0
    except (OSError, ValueError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        report = {"state": "failed", "archive": str(archive), "error": str(error), "runtime_hardware_access_attempted": False}
        status = 1
    rendered = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered)
    sys.stdout.write(rendered)
    return status


if __name__ == "__main__":
    sys.exit(main())
