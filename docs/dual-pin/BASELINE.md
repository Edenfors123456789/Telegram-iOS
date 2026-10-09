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

No product source has been changed. The complete original application build is now confirmed; details follow. Full logs are under ignored `build-input/dual-pin-stage0/`.

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

## Verified full application build

The resource-limited retry completed with exit 0: 834.901 seconds, 6,104 executed actions. Product/build-system files and all submodule pins remain identical to the upstream SHA above.

- Record: `build-input/dual-pin-stage0/baseline-build-20261009T191730Z.json`.
- Log: matching `.log` file.
- Retained original IPA: `build-input/dual-pin-stage0/artifacts/Telegram-original-simulator.ipa`.
- Size: 604,373,337 bytes.
- SHA-256: `d15924a64def71b005f02ae7f3f317156fa407b0b1a3548334e4a65a10612c7e`.
- Bundle `ph.telegra.Telegraph`, app 13.0/build 1, `iphonesimulator`, SDK 27.0, min iOS 15.0, Xcode 27A266a.

## Simulator smoke verification

A new isolated iPhone 17 / iOS 26.5 simulator was created: `4ED48241-0C93-4E6D-B05F-C185F0842C62` (`TG Fork Baseline - isolated`). MobileBuildMCP installed and launched the exact retained IPA. The process stayed alive, and both the screenshot and semantic UI snapshot showed onboarding, Start Messaging, and the Russian-language control. No real Telegram account was authorized and no real messages were sent.

The first headless accessibility snapshot failed. Calling MobileBuildMCP `open_sim` resolved the environment issue; the subsequent snapshot contained 38 elements and both onboarding controls. Evidence is retained in `baseline-smoke.json` and `baseline-onboarding.jpg`.

The original app's startup log contains fresh-container atomic-state absence, repeated `no such table: t19` diagnostics, a missing CloudKit record, and duplicate runtime accessibility-class warnings. These did not prevent onboarding. They are baseline observations, not proven fixed or caused by this fork. Logged-in behavior remains outside this smoke check.

## Original iOS test suite

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
python3 -u build-system/Make/Make.py \
  --bazel '/Users/negrfors/Desktop/tg fork/build-input/dual-pin-stage0/bazel-resource-limited' \
  --overrideXcodeVersion --cacheDir /tmp/tg-dual-pin-bazel-cache \
  test --configurationPath build-system/appstore-configuration.json \
  --codesigningInformationPath build-system/fake-codesigning \
  --target //submodules/TextFormat:TextFormatTests
```

Exit 0; 306 XCTest cases passed, 0 failures. Overall 114.254 seconds, simulator runner 92.3 seconds. Log: `build-input/dual-pin-stage0/baseline-ios-tests-retry.log`; detailed XCTest log under `bazel-testlogs/submodules/TextFormat/TextFormatTests/test.log`. Bazel's XML reports the entire iOS bundle as one case; the 306-case count is from XCTest's final summary.

The initial test command used a relative `--bazel` path, which upstream executable resolution rejected before building/running tests. The absolute path above fixes it without a source change.

Stage 0 gate: passed for the documented Xcode-27.0 compatibility toolchain. It does not establish a device-signed IPA, logged-in Telegram behavior, Dual PIN functionality, or the official Xcode-26.6 release build.
