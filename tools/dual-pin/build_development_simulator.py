#!/usr/bin/env python3
"""Build the fork's own simulator identity without device signing profiles.

Uses upstream configuration generation and BazelCommandLine. No Apple profile,
certificate, Xcode project or system selection is modified. Never a device build.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import zipfile


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", type=Path, default=root / "build-input/dual-pin/configuration.development.json")
    parser.add_argument("--developer-dir", default="/Applications/Xcode.app/Contents/Developer")
    parser.add_argument("--build-number", type=int, default=4)
    parser.add_argument("--swift-strategy", choices=("worker", "local"), default="worker",
                        help="Use local for a diagnosed persistent-worker compiler-plugin stall")
    args = parser.parse_args()
    if args.build_number < 1:
        parser.error("build number must be positive")
    configuration = args.configuration.resolve()
    values = json.loads(configuration.read_text())
    if not re.fullmatch(r"[A-Za-z0-9]+(?:\.[A-Za-z0-9-]+){2,}", values["bundle_id"]):
        parser.error("invalid bundle identifier")
    if not re.fullmatch(r"[A-Z0-9]{10}", values["team_id"]):
        parser.error("invalid team identifier")
    # The upstream writer interpolates Starlark strings; reject injected source.
    if any(isinstance(v, str) and any(c in v for c in '\n\r"\\') for v in values.values()):
        parser.error("configuration strings contain unsupported source characters")
    versions = json.loads((root / "versions.json").read_text())
    version, expected = versions["bazel"].split(":", 1)
    bazel = root / "build-input" / ("bazel-" + version + "-darwin-arm64")
    if hashlib.sha256(bazel.read_bytes()).hexdigest() != expected:
        parser.error("pinned Bazel digest mismatch")
    output = root / "build-input/dual-pin-development"
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run = output / stamp
    run.mkdir(mode=0o700)
    repository = run / "configuration-repository"
    repository.mkdir(mode=0o700)
    (repository / "MODULE.bazel").write_text('module(name = "build_configuration")\n')
    (repository / "WORKSPACE").touch()
    (repository / "BUILD").touch()
    (repository / "provisioning").mkdir()
    (repository / "provisioning/BUILD").write_text("exports_files([])\n")
    os.chdir(root)
    sys.path.insert(0, str(root / "build-system/Make"))
    from BuildConfiguration import build_configuration_from_json
    build_configuration_from_json(str(configuration)).write_to_variables_file(
        bazel_path=str(bazel), use_xcode_managed_codesigning=False,
        aps_environment="development", path=str(repository / "variables.bzl"))
    (repository / "variables.bzl").chmod(0o600)
    environment = os.environ.copy()
    environment["DEVELOPER_DIR"] = str(Path(args.developer_dir).resolve())
    # Run upstream Make's command builder in a child with scoped Xcode. The
    # module override isolates configuration from ordinary fixture Make runs.
    code = """
import sys
sys.path.insert(0, sys.argv[1])
from Make import BazelCommandLine
command = BazelCommandLine(bazel=sys.argv[2], override_bazel_version=False,
    override_xcode_version=True, bazel_user_root=None)
if sys.argv[5] == 'local':
    # Make passes literal quotes in Swift copts. Persistent-worker requests strip
    # them; a one-shot response-file invocation does not. Preserve option values.
    command.common_debug_args = [arg.replace('copt="', 'copt=', 1).removesuffix('"')
        for arg in command.common_debug_args]
command.set_lock(True)
command.set_configuration('debug_sim_arm64')
command.set_build_number(sys.argv[4])
command.set_disable_provisioning_profiles()
command.add_cache_dir('/tmp/tg-dual-pin-bazel-cache')
command.common_args += ['--override_module=build_configuration=' + sys.argv[3],
    '--jobs=3', '--local_resources=memory=8192', '--worker_max_instances=2',
    '--strategy=SwiftCompile=' + sys.argv[5]]
command.invoke_build()
"""
    log = run / "build.log"
    with log.open("x") as stream:
        log.chmod(0o600)
        result = subprocess.run([sys.executable, "-u", "-c", code,
            str(root / "build-system/Make"), str(bazel), str(repository), str(args.build_number), args.swift_strategy],
            cwd=root, env=environment, stdout=stream, stderr=subprocess.STDOUT)
    metadata = {"exit_status": result.returncode, "log": str(log),
        "configuration": str(configuration), "simulator_only": True,
        "device_signing_verified": False, "profiles_used": False, "swift_strategy": args.swift_strategy}
    if result.returncode == 0:
        artifact = run / "Telegram.ipa"
        shutil.copy2(root / "bazel-bin/Telegram/Telegram.ipa", artifact)
        digest = hashlib.sha256()
        with artifact.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        with zipfile.ZipFile(artifact) as archive:
            info = plistlib.loads(archive.read("Payload/Telegram.app/Info.plist"))
        if info["CFBundleIdentifier"] != values["bundle_id"] or info["DTPlatformName"] != "iphonesimulator":
            raise RuntimeError("fresh artifact identity/platform mismatch")
        metadata.update(artifact=str(artifact), bytes=artifact.stat().st_size, sha256=digest.hexdigest(),
            bundle_id=info["CFBundleIdentifier"], build=info["CFBundleVersion"],
            version=info["CFBundleShortVersionString"], platform=info["DTPlatformName"],
            sdk=info["DTSDKName"], xcode_build=info["DTXcodeBuild"])
    (run / "result.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(metadata, indent=2))
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
