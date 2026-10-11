load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

swift_library(
    name = "AccessModeAccountBridge",
    module_name = "AccessModeAccountBridge",
    srcs = glob(["Sources/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    deps = ["//submodules/AccessModeCore", "//submodules/TelegramCore", "//submodules/Postbox", "//submodules/TelegramApi", "//submodules/SSignalKit/SwiftSignalKit", "//submodules/MtProtoKit"],
    visibility = ["//visibility:public"],
)

swift_library(
    name = "AccessModeAccountBridgeTestsLib",
    testonly = True,
    srcs = glob(["Tests/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    deps = [":AccessModeAccountBridge", "//submodules/AccessModeCore", "//submodules/TelegramCore", "//submodules/Postbox", "//submodules/SSignalKit/SwiftSignalKit", "//submodules/MtProtoKit"],
)

ios_test_runner(name = "AccessModeAccountBridgeTestRunner", device_type = "iPhone 17", os_version = "26.5")
ios_unit_test(
    name = "AccessModeAccountBridgeTests",
    minimum_os_version = "15.0",
    runner = ":AccessModeAccountBridgeTestRunner",
    test_host = "//submodules/AccessModeCore:AccessModeCoreTestHost",
    deps = [":AccessModeAccountBridgeTestsLib"],
)
