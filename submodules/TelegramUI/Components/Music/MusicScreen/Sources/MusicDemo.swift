import Foundation
import UIKit
import AVFoundation
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramUIPreferences

/// The demo build's content (`isMusicDemoBuild`): made-up people, chats and music, so the demo video shows nothing
/// real. Audio and covers are generated on the device the first time (no files ship with the app); the chats, the
/// profiles' music and the library state are written again on launch with `-MusicDemoReset YES`.
enum MusicDemo {
    struct PlaylistSpec {
        let id: Int
        let title: String
        let description: String
        let isFavorite: Bool
        let fileIds: [Int64]
        let coverFileId: Int64?
    }

    private struct Track {
        let title: String
        let artist: String
    }

    private static let tracks: [Track] = [
        Track(title: "Sunrise Avenue", artist: "Paper Lanterns"),
        Track(title: "Paper Planes", artist: "Paper Lanterns"),
        Track(title: "Lantern Light", artist: "Paper Lanterns"),
        Track(title: "Midnight Run", artist: "Neon Harbor"),
        Track(title: "City Glow", artist: "Neon Harbor"),
        Track(title: "Harbor Lights", artist: "Neon Harbor"),
        Track(title: "Sunflower", artist: "Mila Rose"),
        Track(title: "Velvet Sky", artist: "Mila Rose"),
        Track(title: "Still Water", artist: "The Quiet Hours"),
        Track(title: "Slow Motion Rain", artist: "The Quiet Hours"),
        Track(title: "Open Fields", artist: "Kite Season"),
        Track(title: "Summer Kites", artist: "Kite Season"),
        Track(title: "Salt & Sand", artist: "Low Tide"),
        Track(title: "Undertow", artist: "Low Tide"),
        Track(title: "Neon Dreams", artist: "Juno Park"),
        Track(title: "Late Checkout", artist: "Juno Park"),
        Track(title: "Static Hearts", artist: "Velvet Static"),
        Track(title: "Afterglow", artist: "Velvet Static"),
        Track(title: "Morning Coffee", artist: "Mila Rose"),
        Track(title: "Northern Line", artist: "Neon Harbor"),
        Track(title: "Sunday Drive", artist: "Kite Season"),
        Track(title: "Wildflowers", artist: "Mila Rose"),
        Track(title: "Echo Park", artist: "Juno Park"),
        Track(title: "Blue Hour", artist: "The Quiet Hours")
    ]

    /// Fixed ids, so playlists and favorites can name the files before they exist.
    private static func audioFileId(_ index: Int) -> Int64 {
        return 7_700_000 + Int64(index)
    }

    private static func trackCoverFileId(_ index: Int) -> Int64 {
        return 7_710_000 + Int64(index)
    }

    private static func playlistCoverFileId(_ index: Int) -> Int64 {
        return 7_720_000 + Int64(index)
    }

    private static func duration(_ index: Int) -> Double {
        return 36.0 + Double(index % 4) * 6.0
    }

    private static func file(_ index: Int) -> TelegramMediaFile {
        let track = MusicDemo.tracks[index]
        let cover = TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 600, height: 600), resource: LocalFileMediaResource(fileId: trackCoverFileId(index)), progressiveSizes: [], immediateThumbnailData: nil, hasVideo: false, isPersonal: false)
        return TelegramMediaFile(fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: audioFileId(index)), partialReference: nil, resource: LocalFileMediaResource(fileId: audioFileId(index)), previewRepresentations: [cover], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "audio/mp4", size: nil, attributes: [.FileName(fileName: "\(track.title).m4a"), .Audio(isVoice: false, duration: Int(duration(index)), title: track.title, performer: track.artist, waveform: nil)], alternativeRepresentations: [])
    }

    // MARK: People and chats

    private static let anna = musicDemoPeerId(index: 0, isGroup: false)
    private static let leo = musicDemoPeerId(index: 1, isGroup: false)
    private static let mia = musicDemoPeerId(index: 2, isGroup: false)
    private static let sam = musicDemoPeerId(index: 3, isGroup: false)
    private static let nora = musicDemoPeerId(index: 4, isGroup: false)
    private static let theo = musicDemoPeerId(index: 5, isGroup: false)
    private static let weekendTrip = musicDemoPeerId(index: 0, isGroup: true)
    private static let indieFinds = musicDemoPeerId(index: 1, isGroup: true)
    private static let designTeam = musicDemoPeerId(index: 2, isGroup: true)
    private static let runningClub = musicDemoPeerId(index: 3, isGroup: true)
    /// Two music bots: their tracks are also in other chats (older here, so the library keeps the same rows), so
    /// choosing only them as sources leaves exactly their tracks.
    private static let lofiBot = musicDemoPeerId(index: 6, isGroup: false)
    private static let indieBot = musicDemoPeerId(index: 7, isGroup: false)

    /// Anna's playlist in her chat: hers, so it is not among the account's playlists.
    static let foreignPlaylistId = 900
    private static let foreignPlaylistTitle = "Road Trip"
    private static let foreignPlaylistTracks = [0, 11, 14, 6, 10, 3]
    private static let foreignPlaylistCoverIndex = 9

    private static let playlists: [(title: String, description: String, isFavorite: Bool, tracks: [Int], hasCover: Bool)] = [
        ("Late Night Drive", "Neon, rain and empty roads", true, [3, 4, 5, 19, 14, 15, 16, 17, 9, 8, 13, 22], true),
        ("Focus", "Quiet songs for deep work", false, [8, 9, 23, 12, 13, 2, 1, 10], true),
        ("Morning Run", "", false, [6, 11, 0, 18, 10, 14], true),
        ("Chill Weekend", "", false, [7, 18, 8, 23, 22], false)
    ]
    private static let favoriteTracks = [0, 6, 17, 4, 9]
    /// Anna's tracks that are not in Music yet, so the video can add them from the chat.
    private static let tracksOutOfMusic = [20, 21]
    private static let annaProfileTracks = [7, 0, 11]

    private static func seed(foreignPlaylistWebpage: TelegramMediaWebpage) -> MusicDemoSeed {
        let now = Int32(Date().timeIntervalSince1970)
        var messages: [MusicDemoSeed.Message] = []
        var nextIds: [EnginePeer.Id: Int32] = [:]
        // Each chat's messages, oldest first, ending `endsAgo` seconds before now, a few minutes apart.
        func chat(_ peerId: EnginePeer.Id, endsAgo: Int32, _ items: [(author: EnginePeer.Id?, text: String, track: Int?)], groupedTracks: Set<Int> = []) {
            let groupingKey = Int64(peerId.id._internalGetInt64Value())
            for (offset, item) in items.enumerated() {
                let id = (nextIds[peerId] ?? 0) + 1
                nextIds[peerId] = id
                let timestamp = now - endsAgo - Int32(items.count - offset) * 180
                let isGrouped = item.track.flatMap { groupedTracks.contains($0) } ?? false
                messages.append(MusicDemoSeed.Message(peerId: peerId, id: id, authorId: item.author, timestamp: timestamp, text: item.text, file: item.track.flatMap { MusicDemo.file($0) }, groupingKey: isGrouped ? groupingKey : nil))
            }
        }

        chat(anna, endsAgo: 240, [
            (anna, "Hey! Are you still up for the road trip on Saturday?", nil),
            (nil, "Of course! I'm on music duty 🎧", nil),
            (anna, "Found a few songs for the drive", nil),
            (anna, "", 7),
            (anna, "", 20),
            (anna, "", 21),
            (anna, "", 22),
            (nil, "Love these, especially the last one", nil)
        ], groupedTracks: [7, 20, 21, 22])
        let roadTripId = (nextIds[anna] ?? 0) + 1
        nextIds[anna] = roadTripId
        messages.append(MusicDemoSeed.Message(peerId: anna, id: roadTripId, authorId: anna, timestamp: now - 200, text: "Made this for our trip 🚗", webpage: foreignPlaylistWebpage))
        let lastAnnaId = roadTripId + 1
        messages.append(MusicDemoSeed.Message(peerId: anna, id: lastAnnaId, authorId: anna, timestamp: now - 120, text: "Can't wait for Saturday!"))

        chat(weekendTrip, endsAgo: 25 * 60, [
            (leo, "Who's driving on Saturday?", nil),
            (nil, "I can drive, Anna's bringing snacks", nil),
            (mia, "Perfect 🙌", nil),
            (leo, "", 11),
            (nora, "", 3),
            (mia, "", 15),
            (leo, "Leaving at 9, don't be late!", nil)
        ])
        chat(indieFinds, endsAgo: 60 * 60, [
            (nora, "New this week ✨", 1),
            (theo, "", 2),
            (nora, "Perfect for a rainy evening", 9),
            (theo, "", 8),
            (nora, "", 4),
            (theo, "This one grows on you", 12),
            (nora, "", 13),
            (theo, "", 16),
            (nora, "", 17),
            (theo, "Weekend pick 🎶", 19)
        ])
        chat(leo, endsAgo: 2 * 60 * 60, [
            (leo, "This band is playing next month", 5),
            (nil, "Let's go!", nil),
            (leo, "", 23),
            (leo, "Sent you the tickets", nil)
        ])
        chat(designTeam, endsAgo: 3 * 60 * 60, [
            (mia, "Updated the mockups, take a look", nil),
            (theo, "Looks great!", nil),
            (nil, "Nice work 👏", nil),
            (mia, "This one's for focus", 0),
            (theo, "Haha, on repeat now", nil)
        ])
        chat(mia, endsAgo: 5 * 60 * 60, [
            (mia, "", 18),
            (nil, "Such a good morning song", nil),
            (mia, "", 10),
            (mia, "Haha, that's perfect 😄", nil)
        ])
        chat(sam, endsAgo: 26 * 60 * 60, [
            (sam, "Are we still on for Friday?", nil),
            (nil, "Yes! 7 pm?", nil),
            (sam, "See you there 👍", nil)
        ])
        chat(runningClub, endsAgo: 50 * 60 * 60, [
            (theo, "Tomorrow 7:00 at the park", nil),
            (sam, "New running playlist starts with this", 6),
            (leo, "", 14),
            (nil, "I'll be there", nil),
            (theo, "Great, see you all!", nil)
        ])

        chat(lofiBot, endsAgo: 4 * 24 * 60 * 60, [
            (nil, "/start", nil),
            (lofiBot, "Hi! I send a calm mix every morning ☕️", nil),
            (lofiBot, "", 8),
            (lofiBot, "", 9),
            (lofiBot, "", 23),
            (lofiBot, "", 18),
            (lofiBot, "Have a slow morning!", nil)
        ])
        chat(indieBot, endsAgo: 5 * 24 * 60 * 60, [
            (nil, "/start", nil),
            (indieBot, "Fresh indie picks, every Friday 🎸", nil),
            (indieBot, "", 10),
            (indieBot, "", 11),
            (indieBot, "", 1),
            (indieBot, "", 12),
            (indieBot, "See you next Friday!", nil)
        ])

        let peers: [MusicDemoSeed.Peer] = [
            MusicDemoSeed.Peer(id: anna, kind: .user(firstName: "Anna", lastName: "Kovacs", isInChatList: true), unreadCount: 2),
            MusicDemoSeed.Peer(id: leo, kind: .user(firstName: "Leo", lastName: "Martin", isInChatList: true)),
            MusicDemoSeed.Peer(id: mia, kind: .user(firstName: "Mia", lastName: "Chen", isInChatList: true)),
            MusicDemoSeed.Peer(id: sam, kind: .user(firstName: "Sam", lastName: "Rivera", isInChatList: true), unreadCount: 1),
            MusicDemoSeed.Peer(id: nora, kind: .user(firstName: "Nora", lastName: "Blake", isInChatList: false)),
            MusicDemoSeed.Peer(id: theo, kind: .user(firstName: "Theo", lastName: "Grant", isInChatList: false)),
            MusicDemoSeed.Peer(id: weekendTrip, kind: .group(title: "Weekend Trip", memberCount: 4), unreadCount: 3),
            MusicDemoSeed.Peer(id: indieFinds, kind: .group(title: "Indie Finds", memberCount: 248), unreadCount: 4),
            MusicDemoSeed.Peer(id: designTeam, kind: .group(title: "Design Team", memberCount: 6)),
            MusicDemoSeed.Peer(id: runningClub, kind: .group(title: "Running Club", memberCount: 12)),
            MusicDemoSeed.Peer(id: lofiBot, kind: .bot(name: "Lo-Fi Music Bot")),
            MusicDemoSeed.Peer(id: indieBot, kind: .bot(name: "Indie Music Bot"))
        ]
        return MusicDemoSeed(peers: peers, messages: messages, savedMusic: [anna: annaProfileTracks.map { MusicDemo.file($0) }], accountSavedMusic: [])
    }

    private static func coverRepresentation(fileId: Int64) -> TelegramMediaImageRepresentation {
        return TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 600, height: 600), resource: LocalFileMediaResource(fileId: fileId), progressiveSizes: [], immediateThumbnailData: nil, hasVideo: false, isPersonal: false)
    }

    /// Who a playlist belongs to when it is not the account's: Anna's playlist from her chat.
    static func ownerPeerId(playlistId: Int) -> EnginePeer.Id? {
        guard isMusicDemoBuild, playlistId == MusicDemo.foreignPlaylistId else {
            return nil
        }
        return MusicDemo.anna
    }

    /// Anna's playlist, made of tracks that are also in the account's Music, so it plays from her bubble.
    static func foreignPlaylist(id: Int, library: MusicLibrary) -> MusicPlaylist? {
        guard id == MusicDemo.foreignPlaylistId else {
            return nil
        }
        var trackIds: [EngineMessage.Id] = []
        for index in MusicDemo.foreignPlaylistTracks {
            if let track = library.track(fileId: audioFileId(index)) {
                trackIds.append(track.message.id)
            }
        }
        let now = Int32(Date().timeIntervalSince1970)
        return MusicPlaylist(id: id, title: MusicDemo.foreignPlaylistTitle, description: "", isFavorite: false, trackIds: trackIds, cover: coverRepresentation(fileId: playlistCoverFileId(MusicDemo.foreignPlaylistCoverIndex)), dateAdded: now, dateUpdated: now)
    }

    // MARK: Preparing

    private struct Marker: Codable {
        let version: Int32
    }

    private static let markerVersion: Int32 = 1
    private static var markerKey: EngineDataBuffer {
        let key = EngineDataBuffer(length: 4)
        key.setInt32(0, value: 40)
        return key
    }

    private static var readiness: [AccountRecordId: ValuePromise<Bool>] = [:]

    /// Completes once the demo content is in place; the first call on a launch writes it if needed. Main queue only.
    static func prepare(context: AccountContext) -> Signal<Never, NoError> {
        let accountId = context.account.id
        let isReady: ValuePromise<Bool>
        if let current = MusicDemo.readiness[accountId] {
            isReady = current
        } else {
            isReady = ValuePromise<Bool>(false, ignoreRepeated: true)
            MusicDemo.readiness[accountId] = isReady
            let _ = MusicDemo.write(context: context).start(completed: {
                isReady.set(true)
            })
        }
        return isReady.get()
        |> filter { $0 }
        |> take(1)
        |> ignoreValues
    }

    private static func write(context: AccountContext) -> Signal<Never, NoError> {
        let reset = UserDefaults.standard.bool(forKey: "MusicDemoReset")
        let collectionId = ApplicationSpecificItemCacheCollectionId.music
        return context.engine.data.get(TelegramEngine.EngineData.Item.ItemCache.Item(collectionId: collectionId, id: MusicDemo.markerKey))
        |> mapToSignal { entry -> Signal<Never, NoError> in
            let isWritten = entry?.get(Marker.self)?.version == MusicDemo.markerVersion
            if isWritten && !reset {
                return .complete()
            }
            let media: Signal<Never, NoError> = isWritten ? .complete() : MusicDemo.generateMedia(context: context)
            return media
            |> then(deferred {
                return MusicDemo.writeContent(context: context)
            })
            |> then(context.engine.itemCache.put(collectionId: collectionId, id: MusicDemo.markerKey, item: Marker(version: MusicDemo.markerVersion)))
        }
    }

    private static func writeContent(context: AccountContext) -> Signal<Never, NoError> {
        let now = Int32(Date().timeIntervalSince1970)
        let roadTrip = MusicPlaylist(id: MusicDemo.foreignPlaylistId, title: MusicDemo.foreignPlaylistTitle, description: "", isFavorite: false, trackIds: [], cover: coverRepresentation(fileId: playlistCoverFileId(MusicDemo.foreignPlaylistCoverIndex)), dateAdded: now, dateUpdated: now)
        let webpage = musicSharedPlaylistWebpage(playlist: roadTrip, files: MusicDemo.foreignPlaylistTracks.map { MusicDemo.file($0) }, ownerName: "Anna Kovacs")
        let playlists = MusicDemo.playlists.enumerated().map { index, playlist in
            return PlaylistSpec(id: index, title: playlist.title, description: playlist.description, isFavorite: playlist.isFavorite, fileIds: playlist.tracks.map { audioFileId($0) }, coverFileId: playlist.hasCover ? playlistCoverFileId(index) : nil)
        }
        return context.engine.messages.seedMusicDemo(MusicDemo.seed(foreignPlaylistWebpage: webpage))
        |> then(musicDemoWriteLibraryState(context: context, playlists: playlists, favoriteFileIds: MusicDemo.favoriteTracks.map { audioFileId($0) }, removedFileIds: MusicDemo.tracksOutOfMusic.map { audioFileId($0) }, tabIsShown: false))
    }

    // MARK: Generated media

    private static func generateMedia(context: AccountContext) -> Signal<Never, NoError> {
        return Signal { subscriber in
            Queue.concurrentDefaultQueue().async {
                for index in 0 ..< MusicDemo.tracks.count {
                    if let data = MusicDemo.audioData(index: index) {
                        context.engine.resources.storeResourceData(id: EngineMediaResource.Id(LocalFileMediaResource(fileId: audioFileId(index)).id), data: data, synchronous: true)
                    }
                    if let data = MusicDemo.coverData(seed: index) {
                        context.engine.resources.storeResourceData(id: EngineMediaResource.Id(LocalFileMediaResource(fileId: trackCoverFileId(index)).id), data: data, synchronous: true)
                    }
                }
                for index in 0 ..< 10 {
                    if let data = MusicDemo.coverData(seed: 100 + index * 7) {
                        context.engine.resources.storeResourceData(id: EngineMediaResource.Id(LocalFileMediaResource(fileId: playlistCoverFileId(index)).id), data: data, synchronous: true)
                    }
                }
                subscriber.putCompletion()
            }
            return EmptyDisposable
        }
    }

    /// An abstract cover: a diagonal gradient with a few soft circles, colours from the seed.
    private static func coverData(seed: Int) -> Data? {
        var random = MusicDemoRandom(seed: UInt64(seed) &* 2654435761 &+ 1)
        let size = CGSize(width: 600, height: 600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let image = UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
            let context = rendererContext.cgContext
            let hue = CGFloat(random.next(1000)) / 1000.0
            let first = UIColor(hue: hue, saturation: 0.55 + CGFloat(random.next(30)) / 100.0, brightness: 0.85, alpha: 1.0)
            let second = UIColor(hue: (hue + 0.12 + CGFloat(random.next(25)) / 100.0).truncatingRemainder(dividingBy: 1.0), saturation: 0.7, brightness: 0.45 + CGFloat(random.next(25)) / 100.0, alpha: 1.0)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: [first.cgColor, second.cgColor] as CFArray, locations: [0.0, 1.0]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: 0.0), end: CGPoint(x: size.width, y: size.height), options: [])
            }
            for _ in 0 ..< 4 {
                let radius = CGFloat(80 + random.next(160))
                let center = CGPoint(x: CGFloat(random.next(600)), y: CGFloat(random.next(600)))
                let color = UIColor(white: 1.0, alpha: 0.08 + CGFloat(random.next(12)) / 100.0)
                context.setFillColor(color.cgColor)
                context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2.0, height: radius * 2.0))
            }
        }
        return image.jpegData(compressionQuality: 0.85)
    }

    /// A short instrumental loop: a soft chord pad, a plucked arpeggio and a quiet kick, key and tempo from the index.
    private static func audioData(index: Int) -> Data? {
        let sampleRate = 44100.0
        let seconds = MusicDemo.duration(index)
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount), let channels = buffer.floatChannelData else {
            return nil
        }
        buffer.frameLength = frameCount

        let root = 110.0 * pow(2.0, Double((index * 5) % 12) / 12.0)
        let tempo = 84.0 + Double((index * 7) % 5) * 8.0
        let beat = 60.0 / tempo
        let chordLength = beat * 4.0
        let progressions: [[(Int, Bool)]] = [
            [(0, true), (7, true), (9, false), (5, true)],
            [(9, false), (5, true), (0, true), (7, true)],
            [(0, true), (5, true), (9, false), (7, true)],
            [(2, false), (7, true), (0, true), (9, false)]
        ]
        let progression = progressions[index % progressions.count]
        let left = channels[0]
        let right = channels[1]
        let twoPi = 2.0 * Double.pi
        for frame in 0 ..< Int(frameCount) {
            let time = Double(frame) / sampleRate
            let chordIndex = Int(time / chordLength) % progression.count
            let (degree, isMajor) = progression[chordIndex]
            let chordRoot = root * pow(2.0, Double(degree) / 12.0)
            let third = chordRoot * pow(2.0, (isMajor ? 4.0 : 3.0) / 12.0)
            let fifth = chordRoot * pow(2.0, 7.0 / 12.0)
            let chordTime = time.truncatingRemainder(dividingBy: chordLength)
            let padEnvelope = min(1.0, chordTime / 0.6) * min(1.0, (chordLength - chordTime) / 0.3)
            let pad = (sin(twoPi * chordRoot * time) + 0.8 * sin(twoPi * third * time) + 0.7 * sin(twoPi * fifth * time) + 0.3 * sin(twoPi * chordRoot * 0.5 * time)) * 0.07 * padEnvelope

            let step = beat / 2.0
            let stepIndex = Int(time / step)
            let stepTime = time.truncatingRemainder(dividingBy: step)
            let notes = [chordRoot * 2.0, third * 2.0, fifth * 2.0, third * 4.0]
            let note = notes[stepIndex % notes.count]
            let pluck = sin(twoPi * note * time) * exp(-stepTime * 9.0) * 0.12

            let beatTime = time.truncatingRemainder(dividingBy: beat)
            let kickFrequency = 50.0 + 70.0 * exp(-beatTime * 30.0)
            let kick = sin(twoPi * kickFrequency * beatTime) * exp(-beatTime * 12.0) * 0.25

            let fade = min(1.0, time / 1.5) * min(1.0, (seconds - time) / 2.0)
            let pan = 0.5 + 0.3 * sin(twoPi * 0.1 * time)
            left[frame] = Float((pad + pluck * (1.0 - pan) + kick) * fade)
            right[frame] = Float((pad + pluck * pan + kick) * fade)
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("music-demo-\(index)-\(UUID().uuidString).m4a")
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 96000
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        } catch {
            return nil
        }
        return try? Data(contentsOf: url)
    }
}

/// A small deterministic generator, so every device draws the same covers.
private struct MusicDemoRandom {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next(_ upperBound: Int) -> Int {
        self.state ^= self.state << 13
        self.state ^= self.state >> 7
        self.state ^= self.state << 17
        return Int(self.state % UInt64(max(1, upperBound)))
    }
}

/// A playlist shared to a local chat (the test chat, the demo's chats) goes as its bubble; elsewhere as its tracks.
func musicSendsPlaylistBubble(to peerId: EnginePeer.Id) -> Bool {
    return peerId == musicTestChatPeerId || isMusicDemoPeer(peerId)
}
