load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "ChatMessageMusicPlaylistBubbleContentNode",
    module_name = "ChatMessageMusicPlaylistBubbleContentNode",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/LottieSettings:LottieSettings",
        "//submodules/Display",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/TelegramCore",
        "//submodules/TelegramPresentationData",
        "//submodules/AccountContext",
        "//submodules/PhotoResources",
        "//submodules/MusicAlbumArtResources",
        "//submodules/ComponentFlow",
        "//submodules/TelegramUI/Components/EdgeEffect",
        "//submodules/TelegramUI/Components/Chat/ChatMessageDateAndStatusNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageBubbleContentNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageItemCommon",
        "//submodules/TelegramUI/Components/Chat/ChatMessageAttachedContentButtonNode",
        "//submodules/TelegramUI/Components/ChatControllerInteraction",
        "//submodules/ListMessageItem",
        "//submodules/MediaPlayer:UniversalMediaPlayer",
    ],
    visibility = [
        "//visibility:public",
    ],
)
