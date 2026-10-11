load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

swift_library(
    name = "TelegramCore",
    module_name = "TelegramCore",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/TelegramApi:TelegramApi",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/MediaPreuploadRegistry:MediaPreuploadRegistry",
        "//submodules/WebProxyTransport:WebProxyTransport",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Postbox:Postbox",
        "//submodules/CloudData:CloudData",
        "//submodules/EncryptionProvider:EncryptionProvider",
        "//submodules/CryptoUtils:CryptoUtils",
        "//submodules/NetworkLogging:NetworkLogging",
        "//submodules/Reachability:Reachability",
        "//submodules/ManagedFile:ManagedFile",
        "//submodules/Utils/RangeSet:RangeSet",
        "//submodules/Utils/DarwinDirStat",
        "//submodules/Emoji",
        "//submodules/TelegramCore/FlatBuffers",
        "//submodules/TelegramCore/FlatSerialization",
        "//submodules/MurMurHash32",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "TelegramCoreTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":TelegramCore",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramApi:TelegramApi",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/Postbox:Postbox",
        "//submodules/WebProxyTransport:WebProxyTransport",
    ],
)

ios_test_runner(
    name = "TelegramCoreTestRunner",
    device_type = "iPhone 17",
    os_version = "26.5",
)

ios_unit_test(
    name = "TelegramCoreTests",
    minimum_os_version = "15.0",
    runner = ":TelegramCoreTestRunner",
    deps = [
        ":TelegramCoreTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Isolated boundary checks can pass independently of recorded upstream parser
# compatibility failures in the broader TelegramCoreTests bundle.
swift_library(
    name = "NetworkAuthKeyScopeTestsLib",
    testonly = True,
    srcs = ["Tests/NetworkAuthKeyScopeTests.swift"],
    deps = [
        ":TelegramCore",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/TelegramApi:TelegramApi",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
)

ios_unit_test(
    name = "NetworkAuthKeyScopeTests",
    minimum_os_version = "15.0",
    runner = ":TelegramCoreTestRunner",
    deps = [":NetworkAuthKeyScopeTestsLib"],
    visibility = ["//visibility:public"],
)

# Dual PIN: search results that leave out chats hidden from lists.
swift_library(
    name = "HiddenChatSearchResultsTestsLib",
    testonly = True,
    srcs = [
        "Tests/HiddenChatSearchResultsTests.swift",
        "Tests/SparseMessageFixtures.swift",
    ],
    deps = [
        ":TelegramCore",
        "//submodules/Postbox:Postbox",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
)

ios_unit_test(
    name = "HiddenChatSearchResultsTests",
    minimum_os_version = "15.0",
    runner = ":TelegramCoreTestRunner",
    deps = [":HiddenChatSearchResultsTestsLib"],
    visibility = ["//visibility:public"],
)

# Dual PIN: the restricted transcript's boundary from messages.getPeerDialogs.
swift_library(
    name = "RestrictedTranscriptBoundaryTestsLib",
    testonly = True,
    srcs = ["Tests/RestrictedTranscriptBoundaryTests.swift"],
    deps = [
        ":TelegramCore",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramApi:TelegramApi",
    ],
)

ios_unit_test(
    name = "RestrictedTranscriptBoundaryTests",
    minimum_os_version = "15.0",
    runner = ":TelegramCoreTestRunner",
    deps = [":RestrictedTranscriptBoundaryTestsLib"],
    visibility = ["//visibility:public"],
)
