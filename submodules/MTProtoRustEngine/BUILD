load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

# Package.swift next to this file is the macOS (SwiftPM) build of the same sources.

swift_library(
    name = "MTProtoRustEngineMapping",
    module_name = "MTProtoRustEngineMapping",
    srcs = glob(["Sources/MTProtoRustEngineMapping/**/*.swift"]),
    copts = [
        "-warnings-as-errors",
    ],
    visibility = ["//visibility:public"],
)

swift_library(
    name = "MTProtoRustEngine",
    module_name = "MTProtoRustEngine",
    srcs = glob(["Sources/MTProtoRustEngine/**/*.swift"]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        ":MTProtoRustEngineMapping",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/WebProxyTransport:WebProxyTransport",
        "//third-party/mtproto-engine:MTProtoEngineFFI",
    ],
    visibility = ["//visibility:public"],
)

# Host (macOS) test: the mapping module is pure Foundation. The bridge and end-to-end tests stay
# SwiftPM-only (`swift test`), because they need the macOS MTProtoEngineFFI.xcframework.
swift_test(
    name = "MTProtoRustEngineMappingTests",
    srcs = glob(["Tests/MTProtoRustEngineMappingTests/**/*.swift"]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [":MTProtoRustEngineMapping"],
)

swift_library(
    name = "RustAuthKeyScopeTestsLib",
    testonly = True,
    srcs = ["Tests/MTProtoRustEngineTests/RustAuthKeyScopeTests.swift"],
    deps = [
        ":MTProtoRustEngine",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
)

ios_test_runner(
    name = "RustAuthKeyScopeTestRunner",
    device_type = "iPhone 17",
    os_version = "26.5",
)

ios_unit_test(
    name = "RustAuthKeyScopeTests",
    minimum_os_version = "15.0",
    runner = ":RustAuthKeyScopeTestRunner",
    deps = [":RustAuthKeyScopeTestsLib"],
    visibility = ["//visibility:public"],
)
