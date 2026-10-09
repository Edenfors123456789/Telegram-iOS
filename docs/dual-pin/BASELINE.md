# Stage 0 — original Telegram baseline

Baseline: `f1dd7a2dbd02cbbf513e75d5695d8d36d1cf5838`, all 13 pinned submodules. Product sources must remain identical until a full application build succeeds.

## Current build command

Run from the repository root:

```sh
mkdir -p build-input/dual-pin-stage0
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
python3 -u build-system/Make/Make.py \
  --overrideXcodeVersion \
  --cacheDir /tmp/tg-dual-pin-bazel-cache \
  build \
  --configurationPath build-system/appstore-configuration.json \
  --codesigningInformationPath build-system/fake-codesigning \
  --buildNumber 1 \
  --configuration debug_sim_arm64 \
  --lock \
  > build-input/dual-pin-stage0/baseline-simulator-build.log 2>&1
```

The profile files are upstream fixture inputs for a simulator build. They do not authorize a physical-device installation or restricted Apple capabilities. No private signing repository or key import is used.

## Toolchain deviation

The baseline pins Xcode 26.6. This host currently has stable Xcode 27.0 (27A266a) and beta Xcode 27.0 (27A5228h). The command uses stable Xcode through process-scoped `DEVELOPER_DIR` and the documented compatibility option. If successful, report it as a compatibility baseline on this exact toolchain, not a reproduced official Xcode-26.6 release build.

## Known preceding failures

1. Strict version check: required 26.6, installed 27.0; no compilation.
2. Xcode-managed signing: missing `@build_configuration//provisioning:Widget.mobileprovision`; analysis stopped.
3. SwiftPM PasscodeCore: generated FlatSerialization sources absent and duplicate dependency identity; tests did not execute.

## Current result

The fixture-profile build exited 1 after analyzing the complete application (1,223 packages; 74,806 configured targets). The missing provisioning input is resolved. Compilation stopped at `WallpaperBackgroundShaders.air`:

```text
cannot execute tool 'metal' due to missing Metal Toolchain;
use: xcodebuild -downloadComponent MetalToolchain
```

The next environment repair is:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -downloadComponent MetalToolchain
```

Repair completed with exit 0. Xcode reports Metal Toolchain 27A266a installed, and `xcrun metal --version` succeeds (32023.921).

## Reproducible retry

```sh
python3 tools/dual-pin/build_original_simulator.py
```

The helper verifies unchanged upstream product files and submodule pins, verifies the pinned Bazel digest, and invokes the same original Make command with a generated Bazel launcher adding only resource scheduling limits. The full app and its normal extensions remain enabled. Limits are 3 jobs, 8192 MiB scheduled memory, and 2 Swift workers; no compiler checks are suppressed. Logs and JSON evidence are timestamped under `build-input/dual-pin-stage0/`. A successful build records IPA SHA-256 and size. The native failed log above is retained.

No product source has been changed. A successful application build remains unconfirmed. Completed component checks are recorded below. Full logs are under ignored `build-input/dual-pin-stage0/`.

## Completed baseline host checks

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
./build-input/bazel-9.2.0-darwin-arm64 test \
  //submodules/UrlWhitelist:UrlWhitelistTests \
  //third-party/libprisma:SyntaxHighlighterTests \
  //submodules/MTProtoRustEngine:MTProtoRustEngineMappingTests \
  --lockfile_mode=error --test_output=errors --cache_test_results=no \
  --jobs=3 --local_resources=memory=8192 \
  --disk_cache=/tmp/tg-dual-pin-bazel-cache
```

Exit status 0; 3/3 Bazel test targets passed (44.939 seconds). XML evidence contains 7 URL tests, 34 MTProto mapping tests, and 1 C++ executable test: 42 cases, no failures or skips. Log: `build-input/dual-pin-stage0/baseline-host-tests.log`. Upstream Swift ArgumentParser emits non-fatal deprecation warnings with Xcode 27.0. This result does not establish a successful full app build or any Dual PIN functionality.
