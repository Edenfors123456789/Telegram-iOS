load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
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
    deps = [":AccessModeUI"],
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
    test_host = "//submodules/AccessModeCore:AccessModeCoreTestHost",
    deps = [":AccessModeUITestsLib"],
)
