load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

swift_library(
    name = "PasscodeCore",
    module_name = "PasscodeCore",
    srcs = glob(["Sources/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/TelegramCore",
        "//submodules/AccessModeCore",
    ],
    visibility = ["//visibility:public"],
)

swift_library(
    name = "DualPINMigrationTestsLib",
    testonly = True,
    srcs = glob(["Tests/DualPINMigrationTests/*.swift"]),
    copts = ["-warnings-as-errors"],
    deps = [":PasscodeCore", "//submodules/AccessModeCore", "//submodules/TelegramCore", "//submodules/SSignalKit/SwiftSignalKit"],
)

ios_test_runner(
    name = "DualPINMigrationTestRunner",
    device_type = "iPhone 17",
    os_version = "26.5",
)

ios_unit_test(
    name = "DualPINMigrationTests",
    minimum_os_version = "15.0",
    runner = ":DualPINMigrationTestRunner",
    test_host = "//submodules/AccessModeCore:AccessModeCoreTestHost",
    deps = [":DualPINMigrationTestsLib"],
)
