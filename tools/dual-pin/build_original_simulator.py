#!/usr/bin/env python3
"""Build the untouched upstream app and retain resumable stage-0 evidence.

Only a generated Bazel launcher limits build concurrency; application sources,
targets, extensions, compiler diagnostics, and dependency pins remain unchanged.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
from datetime import datetime, timezone


UPSTREAM = "f1dd7a2dbd02cbbf513e75d5695d8d36d1cf5838"
PRODUCT_PATHS = [
    "Telegram", "submodules", "third-party", "build-system", ".bazelrc",
    "MODULE.bazel", "MODULE.bazel.lock", "versions.json", "WORKSPACE",
]


def checked_output(root, command, environment=None):
    return subprocess.check_output(
        command, cwd=root, env=environment, text=True,
        stderr=subprocess.STDOUT,
    ).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--developer-dir", default="/Applications/Xcode.app/Contents/Developer")
    parser.add_argument("--cache-dir", default="/tmp/tg-dual-pin-bazel-cache")
    parser.add_argument("--jobs", type=int, default=3)
    parser.add_argument("--memory-mb", type=int, default=8192)
    args = parser.parse_args()
    if args.jobs < 1 or args.memory_mb < 1024:
        parser.error("jobs must be positive and memory must be at least 1024 MiB")

    root = Path(__file__).resolve().parents[2]
    changes = checked_output(root, ["git", "diff", "--name-only", UPSTREAM, "--", *PRODUCT_PATHS])
    dirty = checked_output(root, ["git", "status", "--porcelain", "--untracked-files=all", "--", *PRODUCT_PATHS])
    submodules = checked_output(root, ["git", "submodule", "status"])
    if changes or dirty or any(line[:1] in "+-U" for line in submodules.splitlines()):
        print("Refusing an original-source baseline: product files or pinned submodules differ.", file=sys.stderr)
        if changes:
            print(changes, file=sys.stderr)
        if dirty:
            print(dirty, file=sys.stderr)
        return 2

    versions = json.loads((root / "versions.json").read_text())
    version, expected_digest = versions["bazel"].split(":", 1)
    bazel = root / "build-input" / ("bazel-" + version + "-darwin-arm64")
    if not bazel.is_file():
        print("Pinned Bazel is absent; run upstream Make.py --help to bootstrap it.", file=sys.stderr)
        return 2
    if hashlib.sha256(bazel.read_bytes()).hexdigest() != expected_digest:
        print("Pinned Bazel SHA-256 mismatch.", file=sys.stderr)
        return 2

    environment = os.environ.copy()
    environment["DEVELOPER_DIR"] = str(Path(args.developer_dir).resolve())
    xcode = checked_output(root, ["/usr/bin/xcodebuild", "-version"], environment)
    output = root / "build-input" / "dual-pin-stage0"
    output.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    log = output / ("baseline-build-" + stamp + ".log")
    launcher = output / "bazel-resource-limited"
    resource_flags = [
        "--jobs=" + str(args.jobs),
        "--local_resources=memory=" + str(args.memory_mb),
        "--worker_max_instances=2",
    ]
    launcher.write_text(
        "#!" + sys.executable + "\n"
        "import os, shlex, sys\n"
        "real = " + repr(str(bazel)) + "\n"
        "arguments = sys.argv[1:]\n"
        "if 'build' in arguments or 'test' in arguments:\n"
        "    arguments += " + repr(resource_flags) + "\n"
        "    print('Stage0 Bazel: ' + shlex.join([real] + arguments), flush=True)\n"
        "os.execv(real, [real] + arguments)\n",
        encoding="utf-8",
    )
    launcher.chmod(0o700)
    command = [
        sys.executable, "-u", "build-system/Make/Make.py",
        "--bazel", str(launcher), "--overrideXcodeVersion",
        "--cacheDir", args.cache_dir, "build",
        "--configurationPath", "build-system/appstore-configuration.json",
        "--codesigningInformationPath", "build-system/fake-codesigning",
        "--buildNumber", "1", "--configuration", "debug_sim_arm64", "--lock",
    ]
    evidence = {
        "upstream": UPSTREAM,
        "source_check": "unchanged product files and pinned submodules",
        "started_utc": stamp,
        "developer_dir": environment["DEVELOPER_DIR"],
        "xcode": xcode,
        "expected_xcode": versions["xcode"],
        "bazel_sha256": expected_digest,
        "command": command,
        "resource_flags": resource_flags,
        "log": str(log),
        "state": "running",
    }
    record = output / ("baseline-build-" + stamp + ".json")
    record.write_text(json.dumps(evidence, indent=2) + "\n")
    print("Building original full app: " + shlex.join(command), flush=True)
    print("Log: " + str(log), flush=True)
    with log.open("w", encoding="utf-8") as stream:
        completed = subprocess.run(command, cwd=root, env=environment, stdout=stream, stderr=subprocess.STDOUT)
    evidence["exit_code"] = completed.returncode
    evidence["finished_utc"] = datetime.now(timezone.utc).isoformat()
    evidence["state"] = "succeeded" if completed.returncode == 0 else "failed"
    ipa = root / "bazel-bin" / "Telegram" / "Telegram.ipa"
    if completed.returncode == 0 and ipa.is_file():
        digest = hashlib.sha256()
        with ipa.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        evidence["artifact"] = {
            "path": str(ipa.resolve()), "bytes": ipa.stat().st_size,
            "sha256": digest.hexdigest(),
        }
    elif completed.returncode == 0:
        evidence["state"] = "artifact_missing"
        evidence["exit_code"] = 2
    record.write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence, indent=2), flush=True)
    if evidence["exit_code"]:
        print("\nLast log lines:\n" + "\n".join(log.read_text(errors="replace").splitlines()[-45:]), flush=True)
    return evidence["exit_code"]


if __name__ == "__main__":
    sys.exit(main())
