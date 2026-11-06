import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import ListMessageItem

/// Images the section's rows share, drawn from the client's assets and cached per theme.
enum MusicResources {
    private final class Cache {
        weak var theme: PresentationTheme?
        var images: [String: UIImage] = [:]
    }

    private static let cache = Cache()

    private static func image(_ key: String, theme: PresentationTheme, generate: () -> UIImage?) -> UIImage? {
        if cache.theme !== theme {
            cache.theme = theme
            cache.images.removeAll()
        }
        if let image = cache.images[key] {
            return image
        }
        let image = generate()
        cache.images[key] = image
        return image
    }

    /// The favorite mark at the end of a row: the call rating's filled star at the size of a trailing accessory.
    static func favoriteMark(theme: PresentationTheme) -> UIImage? {
        return image("favoriteMark", theme: theme, generate: {
            guard let source = generateTintedImage(image: UIImage(bundleImageName: "Call/StarHighlighted"), color: theme.list.disclosureArrowColor) else {
                return nil
            }
            let size = CGSize(width: 14.0, height: 14.0)
            return generateImage(size, rotatedContext: { size, context in
                context.clear(CGRect(origin: CGPoint(), size: size))
                UIGraphicsPushContext(context)
                source.draw(in: CGRect(origin: CGPoint(), size: size))
                UIGraphicsPopContext()
            })
        })
    }

    /// The editable list's green add control: the poll's add-option circle in the constructive color.
    static func addControl(theme: PresentationTheme) -> UIImage? {
        return image("addControl", theme: theme, generate: {
            return generateTintedImage(image: UIImage(bundleImageName: "Item List/AddItemIcon"), color: theme.list.itemDisclosureActions.constructive.fillColor)
        })
    }

    /// The editable list's red remove control, as every editable list draws it.
    static func removeControl(theme: PresentationTheme) -> UIImage? {
        return PresentationResourcesItemList.itemListDeleteIndicatorIcon(theme)
    }

    /// Outline play in a circle, drawn for the Play/Shuffle card after `Chat/Context Menu/Play`
    /// at the shuffle's size with the same 1.33 stroke.
    static func play(theme: PresentationTheme) -> UIImage? {
        return image("play", theme: theme, generate: {
            return generateTintedImage(image: UIImage(bundleImageName: "Music/Play"), color: theme.list.itemAccentColor)
        })
    }

    static func shuffle(theme: PresentationTheme) -> UIImage? {
        return image("shuffle", theme: theme, generate: {
            return generateTintedImage(image: UIImage(bundleImageName: "Music/Shuffle"), color: theme.list.itemAccentColor)
        })
    }
}

func musicChatPresentationData(_ presentationData: PresentationData) -> ChatPresentationData {
    return ChatPresentationData(theme: ChatPresentationThemeData(theme: presentationData.theme, wallpaper: .color(0)), fontSize: presentationData.listsFontSize, strings: presentationData.strings, dateTimeFormat: presentationData.dateTimeFormat, nameDisplayOrder: presentationData.nameDisplayOrder, disableAnimations: false, largeEmoji: false, chatBubbleCorners: presentationData.chatBubbleCorners)
}

func musicTrackCountString(_ strings: PresentationStrings, _ count: Int) -> String {
    if strings.primaryComponent.languageCode.hasPrefix("ru") {
        let mod10 = count % 10
        let mod100 = count % 100
        let word: String
        if mod10 == 1 && mod100 != 11 {
            word = "трек"
        } else if (2 ... 4).contains(mod10) && !(12 ... 14).contains(mod100) {
            word = "трека"
        } else {
            word = "треков"
        }
        return "\(count) \(word)"
    }
    return count == 1 ? "1 track" : "\(count) tracks"
}

/// The second line of a playlist row: its description, or how many tracks it holds.
func musicPlaylistSubtitle(_ strings: PresentationStrings, playlist: MusicPlaylist, library: MusicLibrary) -> String {
    return musicTrackCountString(strings, library.tracks(of: playlist).count)
}

/// Choosing tracks for a playlist. The sheet's screens share one picker; the choice is applied by Done.
final class MusicTrackPicker {
    let playlistTitle: String
    private(set) var trackIds: [EngineMessage.Id]
    let updated = ValuePipe<Void>()
    private let completion: ([EngineMessage.Id]) -> Void

    init(playlistTitle: String, trackIds: [EngineMessage.Id], completion: @escaping ([EngineMessage.Id]) -> Void) {
        self.playlistTitle = playlistTitle
        self.trackIds = trackIds
        self.completion = completion
    }

    func contains(_ track: MusicTrack) -> Bool {
        return self.trackIds.contains(track.message.id)
    }

    func toggle(_ track: MusicTrack) {
        if let index = self.trackIds.firstIndex(of: track.message.id) {
            self.trackIds.remove(at: index)
        } else {
            self.trackIds.append(track.message.id)
        }
        self.updated.putNext(Void())
    }

    func add(_ tracks: [MusicTrack]) {
        for track in tracks where !self.trackIds.contains(track.message.id) {
            self.trackIds.append(track.message.id)
        }
        self.updated.putNext(Void())
    }

    func commit() {
        self.completion(self.trackIds)
    }
}
