load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_application", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

swift_library(
    name = "AccessModeUI",
    module_name = "AccessModeUI",
    srcs = glob(["Sources/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    visibility = ["//visibility:public"],
)

swift_library(
    name = "AccessModeUITestsLib",
    testonly = True,
    srcs = glob(["Tests/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    deps = [":AccessModeUI", "//submodules/Display"],
)

ios_test_runner(
    name = "AccessModeUITestRunner",
    device_type = "iPhone 17",
    os_version = "26.5",
)

ios_unit_test(
    name = "AccessModeUITests",
    minimum_os_version = "15.0",
    runner = ":AccessModeUITestRunner",
    test_host = ":AccessModeUITestHost",
    deps = [":AccessModeUITestsLib"],
)

# Load Display/AsyncDisplayKit in the executable, as Telegram does. Loading its
# Objective-C +load initializer later through XCTest's injected bundle can
# deadlock UIKit's application-context preload while dyld's lock is held.
swift_library(
    name = "AccessModeUITestHostLib",
    testonly = True,
    srcs = ["TestsSupport/TestHost.swift"],
    copts = ["-warnings-as-errors", "-parse-as-library"],
    deps = ["//submodules/Display"],
)

ios_application(
    name = "AccessModeUITestHost",
    testonly = True,
    bundle_id = "org.negrfors.telegram.dualpin.uiTestsHost",
    families = ["iphone", "ipad"],
    infoplists = ["TestsSupport/Info.plist"],
    minimum_os_version = "15.0",
    deps = [":AccessModeUITestHostLib"],
)
