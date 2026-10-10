load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_application", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

swift_library(
    name = "AccessModeCore",
    module_name = "AccessModeCore",
    srcs = glob(["Sources/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    visibility = ["//visibility:public"],
)

swift_test(
    name = "AccessModeCoreTests",
    srcs = glob(["Tests/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    deps = [":AccessModeCore"],
)

swift_library(
    name = "AccessModeCoreIOSTestsLib",
    testonly = True,
    srcs = glob(["Tests/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    deps = [":AccessModeCore"],
)

ios_test_runner(
    name = "AccessModeCoreIOSTestRunner",
    device_type = "iPhone 17",
    os_version = "26.5",
)

ios_unit_test(
    name = "AccessModeCoreIOSTests",
    minimum_os_version = "15.0",
    runner = ":AccessModeCoreIOSTestRunner",
    test_host = ":AccessModeCoreTestHost",
    deps = [":AccessModeCoreIOSTestsLib"],
)

# Keychain requires an application context; an unhosted xctest process has no keychain.
swift_library(
    name = "AccessModeCoreTestHostLib",
    testonly = True,
    srcs = ["TestsSupport/TestHost.swift"],
    copts = ["-warnings-as-errors", "-parse-as-library"],
)

ios_application(
    name = "AccessModeCoreTestHost",
    testonly = True,
    visibility = ["//submodules/AccessModeUI:__pkg__", "//submodules/PasscodeCore:__pkg__", "//submodules/AccessModeAccountBridge:__pkg__"],
    bundle_id = "org.negrfors.telegram.dualpin.testsHost",
    families = ["iphone", "ipad"],
    entitlements = "TestsSupport/TestHost.entitlements",
    infoplists = ["TestsSupport/Info.plist"],
    minimum_os_version = "15.0",
    deps = [":AccessModeCoreTestHostLib"],
)
