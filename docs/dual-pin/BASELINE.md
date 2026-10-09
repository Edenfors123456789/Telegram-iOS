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

Build started; outcome pending. The complete local log is ignored by Git. Update this document with exit status, failure or artifact SHA-256, and baseline test results before advancing.
