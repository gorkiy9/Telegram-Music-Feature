load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "DynamicIslandMask",
    module_name = "DynamicIslandMask",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/AnimationUI",
    ],
    visibility = [
        "//visibility:public",
    ],
)
