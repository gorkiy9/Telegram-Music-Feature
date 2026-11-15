import Foundation
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramUIPreferences
import TelegramPresentationData
import PeerMessagesMediaPlaylist
import LegacyMediaPickerUI
import ICloudResources

struct MusicTrack {
    let message: EngineRawMessage
    let isSaved: Bool

    var file: TelegramMediaFile? {
        for media in self.message.media {
            if let file = media as? TelegramMediaFile {
                return file
            }
        }
        return nil
    }

    private var audio: (title: String?, performer: String?) {
        for attribute in self.file?.attributes ?? [] {
            if case let .Audio(_, _, title, performer, _) = attribute {
                return (title, performer)
            }
        }
        return (nil, nil)
    }

    var title: String {
        return audioTitleWithoutFileExtension(self.audio.title ?? self.file?.fileName ?? "")
    }

    /// Nil for a file without tags: it stays in Songs and has no artist.
    var artist: String? {
        guard let performer = self.audio.performer?.trimmingCharacters(in: .whitespacesAndNewlines), !performer.isEmpty else {
            return nil
        }
        return performer
    }
}

struct MusicArtist {
    let name: String
    let trackCount: Int
}

struct MusicSorting: Equatable {
    enum Key: Equatable {
        case title
        case dateAdded
        case artist
        case lastPlayed
        case dateUpdated
        /// The order a playlist was built in: ascending is that order, descending reverses it.
        case playlistOrder
    }

    var key: Key
    var ascending: Bool

    /// Tapping the selected key reverses it, any other key starts from its natural order.
    func selecting(_ key: Key) -> MusicSorting {
        if key == self.key {
            return MusicSorting(key: key, ascending: !self.ascending)
        }
        switch key {
        case .title, .artist, .playlistOrder:
            return MusicSorting(key: key, ascending: true)
        case .dateAdded, .lastPlayed, .dateUpdated:
            return MusicSorting(key: key, ascending: false)
        }
    }
}

/// The API has no playlists: they are local stand-ins kept in memory until it does.
struct MusicPlaylist: Equatable {
    let id: Int
    var title: String
    var description: String
    var isFavorite: Bool
    /// A local stand-in as well: the profile has no place for playlists.
    var isInProfile: Bool = false
    var trackIds: [EngineMessage.Id]
    /// The cover picked on this device, stored in the media box as a local file.
    var cover: TelegramMediaImageRepresentation? = nil
    /// The emoji or sticker the cover was made from: the playlist draws it animated, as a profile draws an emoji photo.
    var coverMarkup: TelegramMediaImage.EmojiMarkup? = nil
    let dateAdded: Int32
    var dateUpdated: Int32
}

/// Which tracks a list shows.
enum MusicTrackSource: Equatable {
    case all
    case artist(String)
    case favorites
    case playlist(Int)
}

/// Files picked out on this device: the API has neither favorites nor a way to take a chat's file out of the music.
private struct MusicFileIdList: Codable {
    let fileIds: [Int64]
}

/// Files added to Music from outside the account's chats and profile (another profile, an article), kept on
/// this device: Music has no server list of its own, and adding to it never touches the profile.
private struct MusicStoredAddedFiles: Codable {
    struct File: Codable {
        let fileId: Int64
        /// The file in Postbox coding.
        let data: Data
        let timestamp: Int32
    }
    let files: [File]
}

/// Results opened from search on the All tab, newest first (Figma Music / Search, 291:16311). Kept on this device.
private struct MusicStoredRecentSearches: Codable {
    /// Int32: the item cache's encoder has no plain Int.
    let playlistIds: [Int32]
    /// Lowercased, as artists are grouped.
    let artists: [String]
    let fileIds: [Int64]
}

private struct MusicTabSettings: Codable {
    let isShown: Bool
}

/// Playlists kept on this device until the API can hold them. Tracks are kept by their file, which stays the same
/// across launches, while the message a track is listed under may not.
private struct MusicStoredPlaylists: Codable {
    struct FileId: Codable, Hashable {
        let namespace: Int32
        let id: Int64
    }

    struct Cover: Codable {
        /// A `LocalFileMediaResource` in the media box.
        let fileId: Int64
        let width: Int32
        let height: Int32
    }

    struct Playlist: Codable {
        /// Int32: the item cache's encoder has no plain Int.
        let id: Int32
        let title: String
        let description: String
        let isFavorite: Bool
        let isInProfile: Bool
        let fileIds: [FileId]
        let cover: Cover?
        /// Absent in playlists stored before covers could be animated.
        let coverEmoji: CoverEmoji?
        let dateAdded: Int32
        let dateUpdated: Int32
    }

    /// `TelegramMediaImage.EmojiMarkup`: an emoji by file id, or a sticker when the pack is set.
    struct CoverEmoji: Codable {
        let fileId: Int64
        let packId: Int64?
        let packAccessHash: Int64?
        let backgroundColors: [Int32]
    }

    let playlists: [Playlist]
}

/// When each track and playlist was put in the profile, newest wins the profile's music row. Kept on this device:
/// the profile's saved-music list has no dates, and playlists have no server side at all.
private struct MusicStoredProfileDates: Codable {
    struct Track: Codable {
        let fileId: Int64
        let timestamp: Int32
    }
    struct Playlist: Codable {
        /// Int32: the item cache's encoder has no plain Int.
        let id: Int32
        let timestamp: Int32
    }
    let tracks: [Track]
    let playlists: [Playlist]
}

/// What the profile shows in its music row: the last track put in the profile, or the last playlist when it has
/// no tracks. Nil while nothing is there; the row then reads «Медиатека».
public struct MusicProfileSummary: Equatable {
    public let title: String
    public let subtitle: String?
}

/// Title, artist and cover changed on the track edit screen, by file id. Kept on this device: the API cannot
/// change a saved file's metadata.
private struct MusicStoredTrackEdits: Codable {
    struct Edit: Codable {
        let fileId: Int64
        let title: String
        let artist: String
        let cover: MusicStoredPlaylists.Cover?
    }

    let edits: [Edit]
}

struct MusicTrackEdit {
    var title: String
    var artist: String
    var cover: TelegramMediaImageRepresentation?
}

/// The section's local state shares one item cache collection, one entry per kind.
private enum MusicCacheKey: Int32 {
    // 0 held play counts, which nothing reads any more.
    case favorites = 1
    case removed = 2
    case tabSettings = 3
    case playlists = 4
    case trackEdits = 5
    case addedFiles = 6
    case recentSearches = 7
    case sources = 8
    case profileDates = 9

    var buffer: EngineDataBuffer {
        let key = EngineDataBuffer(length: 4)
        key.setInt32(0, value: self.rawValue)
        return key
    }
}

/// Whether the Music tab is in the tab bar; the section is always reachable from Settings.
public func musicTabIsShown(context: AccountContext) -> Signal<Bool, NoError> {
    return context.engine.data.subscribe(TelegramEngine.EngineData.Item.ItemCache.Item(collectionId: ApplicationSpecificItemCacheCollectionId.music, id: MusicCacheKey.tabSettings.buffer))
    |> map { entry -> Bool in
        return entry?.get(MusicTabSettings.self)?.isShown ?? true
    }
    |> distinctUntilChanged
}

func setMusicTabIsShown(context: AccountContext, _ isShown: Bool) {
    let _ = context.engine.itemCache.put(collectionId: ApplicationSpecificItemCacheCollectionId.music, id: MusicCacheKey.tabSettings.buffer, item: MusicTabSettings(isShown: isShown)).startStandalone()
}

/// The chats whose audio files enter Music. The profile's music and files added by hand are listed whatever is chosen.
/// Kept on this device: the API has no such setting.
struct MusicSourceSettings: Codable, Equatable {
    /// False: only `peerIds`.
    var allChats: Bool
    var peerIds: [Int64]

    static let `default` = MusicSourceSettings(allChats: true, peerIds: [])

    var chosenPeerIds: [EnginePeer.Id] {
        return self.peerIds.map { EnginePeer.Id($0) }
    }
}

func musicSourceSettings(context: AccountContext) -> Signal<MusicSourceSettings, NoError> {
    return context.engine.data.subscribe(TelegramEngine.EngineData.Item.ItemCache.Item(collectionId: ApplicationSpecificItemCacheCollectionId.music, id: MusicCacheKey.sources.buffer))
    |> map { entry -> MusicSourceSettings in
        return entry?.get(MusicSourceSettings.self) ?? .default
    }
    |> distinctUntilChanged
}

func setMusicSourceSettings(context: AccountContext, _ settings: MusicSourceSettings) {
    let _ = context.engine.itemCache.put(collectionId: ApplicationSpecificItemCacheCollectionId.music, id: MusicCacheKey.sources.buffer, item: settings).startStandalone()
}

/// The account's music: the tracks saved to its profile and the audio files of all its chats.
/// Both are real server data; a track found in several places is listed once, saved first.
/// Sorting and artists need the whole list, so every page is loaded up front.
/// The section's screens share one library.
final class MusicLibrary {
    private let context: AccountContext
    private let savedMusicContext: ProfileSavedMusicContext

    private var savedMessages: [EngineRawMessage] = [] {
        didSet { self.cachedAllTracks = nil }
    }
    private var savedCanLoadMore = false
    private var didReceiveSavedIds = false
    /// While the profile's list reloads, its earlier pages stay listed, so no track blinks out of Music.
    private var isReloadingSaved = false
    /// Each file's row id as last listed: when a track changes source (a chat's track saved to the profile),
    /// playlists follow it to the new id.
    private var messageIdByFileId: [Int64: EngineMessage.Id] = [:]
    /// Every row's file as ever listed, so a playlist keeps a track its source no longer lists.
    private var listedFileIdByMessageId: [EngineMessage.Id: MusicStoredPlaylists.FileId] = [:]
    private var chatMessages: [EngineRawMessage] = [] {
        didSet { self.cachedAllTracks = nil }
    }
    private var chatSearchState: SearchMessagesState?
    private var chatCanLoadMore = true
    /// True once every page of chat music has arrived, so later changes come from the user.
    public var isFullyLoaded: Bool {
        return !self.chatCanLoadMore
    }
    private var isLoadingChatMessages = false

    private let savedDisposable = MetaDisposable()
    private let savedIdsDisposable = MetaDisposable()
    private let chatLoadDisposable = MetaDisposable()
    private let chatRefreshDisposable = MetaDisposable()
    /// One entry per upload: adding a second track while the first uploads must not cancel it.
    private let uploadDisposables = DisposableSet()
    private let fileListsDisposable = MetaDisposable()
    private let sourcesDisposable = MetaDisposable()
    private let removeAllDisposable = MetaDisposable()
    /// The chats music is taken from; nil for all of them.
    private var sourcePeerIds: Set<EnginePeer.Id>? {
        didSet { self.cachedAllTracks = nil }
    }

    /// Fires on the main queue whenever `allTracks` may have changed.
    let updated = ValuePipe<Void>()

    private(set) var playlists: [MusicPlaylist]
    private var favoriteFileIds = Set<Int64>()
    /// Chat files taken out of the music. Saved tracks are removed from the profile instead.
    private var removedFileIds = Set<Int64>() {
        didSet { self.cachedAllTracks = nil }
    }
    /// Stored tracks of each playlist that are not in the loaded music yet: the chat audio arrives page by page.
    private var pendingPlaylistFileIds: [Int: [MusicStoredPlaylists.FileId]] = [:]
    private var didLoadPlaylists = false
    private var editedPlaylistIds = Set<Int>()
    private let playlistsDisposable = MetaDisposable()
    private let trackEditsDisposable = MetaDisposable()
    private let addedFilesDisposable = MetaDisposable()
    private let recentSearchesDisposable = MetaDisposable()
    private var didLoadRecentSearches = false
    /// Newest first; playlists by id, artists by lowercased name, tracks by file id.
    private(set) var recentSearchPlaylistIds: [Int] = []
    private(set) var recentSearchArtists: [String] = []
    private(set) var recentSearchFileIds: [Int64] = []

    /// What the player goes through when a track is started here; Play Next and Add to Queue edit it while it plays.
    private var queue: [EngineRawMessage] = []
    private let queuePromise = Promise<[EngineRawMessage]>([])
    /// The queue as the player sheet shows it: its tracks and the list they were started from.
    private var queueTitle: String = ""
    private var queueKind: MusicPlayerQueueKind = .tracks
    private var queueIsReversed = false
    /// Shuffle mixed the queue itself, so the list shows the play order and can still be reordered.
    private var queueIsShuffled = false
    /// The order before Shuffle, restored when it is turned off, and whether it was reversed and set by hand then.
    private var queueOrderBeforeShuffle: (ids: [EngineMessage.Id], isReversed: Bool, isCustomized: Bool)?
    /// The list the queue was started from, as it stands now; nil for a shuffled start or a screen that is gone.
    private var queueSource: (() -> [MusicTrack]?)?
    /// Play Next, Add to Queue or a drag changed the order: the source list no longer decides it.
    private var queueIsCustomized = false
    private var playingMessageId: EngineMessage.Id?
    private let playingDisposable = MetaDisposable()
    let queueInfo = ValuePromise<MusicPlayerQueueInfo?>(nil, ignoreRepeated: true)

    private static var sharedLibraries: [AccountRecordId: MusicLibrary] = [:]

    /// One library per account: the tab, the screens pushed from it and the player sheet share it, so a favorite
    /// marked in one place shows everywhere. Main queue only.
    static func shared(context: AccountContext) -> MusicLibrary {
        if let library = MusicLibrary.sharedLibraries[context.account.id] {
            return library
        }
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        let library = MusicLibrary(context: context, playlistTitle: strings.Music_Playlist)
        MusicLibrary.sharedLibraries[context.account.id] = library
        if MusicLibrary.accountsDisposable == nil {
            // A logged-out account's library would keep its context and keep loading: drop it with the account.
            MusicLibrary.accountsDisposable = (context.sharedContext.activeAccountContexts
            |> deliverOnMainQueue).startStrict(next: { accounts in
                let activeIds = Set(accounts.accounts.map(\.0))
                for accountId in MusicLibrary.sharedLibraries.keys where !activeIds.contains(accountId) {
                    MusicLibrary.sharedLibraries[accountId] = nil
                    let _ = MusicLibrary.fileIdsSnapshot.modify { current in
                        var current = current
                        current[accountId] = nil
                        return current
                    }
                }
            })
        }
        return library
    }
    private static var accountsDisposable: Disposable?

    /// When a file or a playlist went into the profile (see `MusicStoredProfileDates`).
    private var trackProfileDates: [Int64: Int32] = [:]
    private var playlistProfileDates: [Int: Int32] = [:]
    private var didLoadProfileDates = false
    private let profileDatesDisposable = MetaDisposable()

    private var trackEdits: [Int64: MusicTrackEdit] = [:] {
        didSet { self.cachedAllTracks = nil }
    }
    private var didLoadTrackEdits = false

    /// A file a chat carries is listed as that chat's message, whether or not it is also in the profile: adding a
    /// chat's track to the profile then changes neither its row nor its date, and the track stays where it was.
    /// Profile-only and device-only files share one local row id, so they too keep their row across the profile.
    /// `allTracks` as last built, with each file's track: rebuilding the list rewrites every message (edits,
    /// listed dates), and it is read many times per update (player state, queue sync, playlists, every screen).
    private var cachedAllTracks: (tracks: [MusicTrack], byFileId: [Int64: MusicTrack])?

    var allTracks: [MusicTrack] {
        return self.allTracksCache().tracks
    }

    private func allTracksCache() -> (tracks: [MusicTrack], byFileId: [Int64: MusicTrack]) {
        if let cached = self.cachedAllTracks {
            return cached
        }
        let tracks = self.buildAllTracks()
        var byFileId: [Int64: MusicTrack] = [:]
        for track in tracks {
            if let fileId = track.file?.fileId.id, byFileId[fileId] == nil {
                byFileId[fileId] = track
            }
        }
        let cached = (tracks: tracks, byFileId: byFileId)
        self.cachedAllTracks = cached
        return cached
    }

    private func buildAllTracks() -> [MusicTrack] {
        var addedTimestamps: [Int64: Int32] = [:]
        for added in self.addedFiles {
            addedTimestamps[added.file.fileId.id] = added.timestamp
        }
        let profileFileIds = self.savedFileIds ?? Set(self.savedMessages.compactMap { musicFileId($0)?.id })
        var fileIds = Set<Int64>()
        var tracks: [MusicTrack] = []
        for message in self.chatMessages {
            if let sourcePeerIds = self.sourcePeerIds, !sourcePeerIds.contains(message.id.peerId) {
                continue
            }
            guard let fileId = musicFileId(message)?.id, !self.removedFileIds.contains(fileId), fileIds.insert(fileId).inserted else {
                continue
            }
            tracks.append(MusicTrack(message: self.applyingEdit(message), isSaved: profileFileIds.contains(fileId)))
        }
        for message in self.savedMessages {
            guard let fileId = musicFileId(message)?.id else {
                tracks.append(MusicTrack(message: self.applyingEdit(message), isSaved: true))
                continue
            }
            guard !self.removedFileIds.contains(fileId), fileIds.insert(fileId).inserted else {
                continue
            }
            let listed = message.timestamp == 0 ? addedTimestamps[fileId].flatMap { message.withUpdatedTimestamp($0) } ?? message : message
            tracks.append(MusicTrack(message: self.applyingEdit(listed), isSaved: true))
        }
        for file in self.addedFiles where !self.removedFileIds.contains(file.file.fileId.id) && fileIds.insert(file.file.fileId.id).inserted {
            tracks.append(MusicTrack(message: self.applyingEdit(self.addedFileMessage(file)), isSaved: profileFileIds.contains(file.file.fileId.id)))
        }
        return tracks
    }

    /// The profile's list has no dates; a file also kept on this device lists with the date it was added there,
    /// so it keeps its place when sorted by date.
    private struct AddedFile {
        let file: TelegramMediaFile
        let timestamp: Int32
    }
    private var addedFiles: [AddedFile] = [] {
        didSet { self.cachedAllTracks = nil }
    }
    private var didLoadAddedFiles = false

    /// An added file is listed as a local message of the account, like saved music (same id scheme; a file is
    /// never listed twice).
    private func addedFileMessage(_ added: AddedFile) -> EngineRawMessage {
        let peerId = self.context.account.peerId
        let stableId = UInt32(clamping: added.file.fileId.id % Int64(Int32.max))
        return EngineRawMessage(stableId: stableId, stableVersion: 0, id: EngineMessage.Id(peerId: peerId, namespace: Namespaces.Message.Local, id: Int32(stableId)), globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: added.timestamp, flags: [], tags: [.music], globalTags: [], localTags: [], customTags: [], forwardInfo: nil, author: nil, text: "", attributes: [], media: [added.file], peers: EngineSimpleDictionary(), associatedMessages: EngineSimpleDictionary(), associatedMessageIds: [], associatedMedia: [:], associatedThreadInfo: nil, associatedStories: [:])
    }

    private func storeAddedFiles() {
        guard self.didLoadAddedFiles else {
            return
        }
        let files = self.addedFiles.map { added -> MusicStoredAddedFiles.File in
            let encoder = EnginePostboxEncoder()
            encoder.encodeRootObject(added.file)
            return MusicStoredAddedFiles.File(fileId: added.file.fileId.id, data: encoder.makeData(), timestamp: added.timestamp)
        }
        let _ = self.context.engine.itemCache.put(collectionId: ApplicationSpecificItemCacheCollectionId.music, id: MusicCacheKey.addedFiles.buffer, item: MusicStoredAddedFiles(files: files)).startStandalone()
    }

    /// Puts the file in Music: a file taken out of it comes back, any other is added on this device.
    /// The profile is not touched.
    func addToMusic(file: TelegramMediaFile) {
        let fileId = file.fileId.id
        if self.removedFileIds.remove(fileId) != nil {
            self.storeFileIds(self.removedFileIds, key: .removed)
        }
        if self.track(fileId: fileId) == nil && !self.addedFiles.contains(where: { $0.file.fileId.id == fileId }) {
            self.addedFiles.append(AddedFile(file: file, timestamp: Int32(Date().timeIntervalSince1970)))
            self.storeAddedFiles()
        }
        self.notifyUpdated()
    }

    /// Keeps files that leave the profile in Music: Music and the profile are separate lists. A file a chat
    /// carries stays through the chat; any other is kept on this device, under the same row id.
    private func keepInMusic(fileIds: Set<Int64>) {
        var didAdd = false
        for fileId in fileIds where !self.removedFileIds.contains(fileId) {
            if self.addedFiles.contains(where: { $0.file.fileId.id == fileId }) || self.chatMessages.contains(where: { musicFileId($0)?.id == fileId }) {
                continue
            }
            guard let message = self.savedMessages.first(where: { musicFileId($0)?.id == fileId }), let file = message.media.first(where: { $0 is TelegramMediaFile }) as? TelegramMediaFile else {
                continue
            }
            self.addedFiles.append(AddedFile(file: file, timestamp: message.timestamp != 0 ? message.timestamp : Int32(Date().timeIntervalSince1970)))
            didAdd = true
        }
        if didAdd {
            self.storeAddedFiles()
        }
    }

    /// Takes the file out of Music whatever its source; the profile and the chats keep it.
    func removeFromMusic(fileId: Int64) {
        self.favoriteFileIds.remove(fileId)
        self.removedFileIds.insert(fileId)
        if let index = self.addedFiles.firstIndex(where: { $0.file.fileId.id == fileId }) {
            self.addedFiles.remove(at: index)
            self.storeAddedFiles()
        }
        self.storeFileIds(self.favoriteFileIds, key: .favorites)
        self.storeFileIds(self.removedFileIds, key: .removed)
        self.notifyUpdated()
    }

    func edit(of track: MusicTrack) -> MusicTrackEdit? {
        guard let fileId = track.file?.fileId.id else {
            return nil
        }
        return self.trackEdits[fileId]
    }

    /// Rows and the player draw the message, so an edited track is the same message with its file's audio tags and cover replaced.
    private func applyingEdit(_ message: EngineRawMessage) -> EngineRawMessage {
        guard !self.trackEdits.isEmpty else {
            return message
        }
        var media = message.media
        guard let index = media.firstIndex(where: { $0 is TelegramMediaFile }), let file = media[index] as? TelegramMediaFile, let edit = self.trackEdits[file.fileId.id] else {
            return message
        }
        media[index] = musicFile(file, title: edit.title, artist: edit.artist, cover: edit.cover)
        return message.withUpdatedMedia(media)
    }

    func setEdit(_ edit: MusicTrackEdit, for track: MusicTrack) {
        guard let fileId = track.file?.fileId.id else {
            return
        }
        self.trackEdits[fileId] = edit
        self.storeTrackEdits()
        self.notifyUpdated()
    }

    private func storeTrackEdits() {
        guard self.didLoadTrackEdits else {
            return
        }
        let edits = self.trackEdits.map { fileId, edit in
            return MusicStoredTrackEdits.Edit(fileId: fileId, title: edit.title, artist: edit.artist, cover: edit.cover.flatMap { cover -> MusicStoredPlaylists.Cover? in
                guard let resource = cover.resource as? LocalFileMediaResource else {
                    return nil
                }
                return MusicStoredPlaylists.Cover(fileId: resource.fileId, width: cover.dimensions.width, height: cover.dimensions.height)
            })
        }
        let _ = self.context.engine.itemCache.put(collectionId: ApplicationSpecificItemCacheCollectionId.music, id: MusicCacheKey.trackEdits.buffer, item: MusicStoredTrackEdits(edits: edits)).startStandalone()
    }

    var favoriteCount: Int {
        return self.allTracks.filter { self.isFavorite($0) }.count
    }

    var artists: [MusicArtist] {
        var counts: [String: Int] = [:]
        var names: [String: String] = [:]
        for track in self.allTracks {
            if let artist = track.artist {
                let key = artist.lowercased()
                counts[key, default: 0] += 1
                if names[key] == nil {
                    names[key] = artist
                }
            }
        }
        return names.map { MusicArtist(name: $0.value, trackCount: counts[$0.key] ?? 0) }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    init(context: AccountContext, playlistTitle: String) {
        self.context = context
        self.savedMusicContext = ProfileSavedMusicContext(account: context.account, peerId: context.account.peerId)
        let now = Int32(Date().timeIntervalSince1970)
        self.playlists = [MusicPlaylist(id: 0, title: playlistTitle, description: "", isFavorite: false, trackIds: [], dateAdded: now, dateUpdated: now)]

        // The saved-music playlist already turns the list into messages; rows and playlist then share their ids.
        let savedLocation = PeerMessagesPlaylistLocation.savedMusic(context: self.savedMusicContext, at: 0, canReorder: false)
        if case let .custom(messages, _, _, _, _) = savedLocation.effectiveLocation(context: context) {
            self.savedDisposable.set((messages
            |> deliverOnMainQueue).start(next: { [weak self] messages, _, canLoadMore in
                guard let self else {
                    return
                }
                if self.isReloadingSaved && canLoadMore {
                    let loaded = Set(messages.compactMap { musicFileId($0) })
                    self.savedMessages = messages + self.savedMessages.filter { message in
                        guard let fileId = musicFileId(message) else {
                            return false
                        }
                        return !loaded.contains(fileId) && self.savedFileIds?.contains(fileId.id) != false
                    }
                } else {
                    self.isReloadingSaved = false
                    self.savedMessages = messages
                }
                self.savedCanLoadMore = canLoadMore
                self.notifyUpdated()
                if canLoadMore {
                    self.savedMusicContext.loadMore()
                }
            }))
        }

        // Saving or removing a track elsewhere goes through another context: only the ids reach this one.
        self.savedIdsDisposable.set((context.engine.peers.savedMusicIds()
        |> distinctUntilChanged
        |> deliverOnMainQueue).start(next: { [weak self] ids in
            guard let self else {
                return
            }
            if let ids, ids != self.savedFileIds {
                // A track taken off the profile elsewhere (the player) stays in Music.
                if let previous = self.savedFileIds {
                    self.keepInMusic(fileIds: previous.subtracting(ids))
                    // Saved elsewhere (the player, another device): put in the profile now, as far as this device knows.
                    self.stampProfileDates(fileIds: ids.subtracting(previous))
                }
                self.savedFileIds = ids
                self.notifyUpdated()
            }
            // The list already shows a change made through this library; any other is fetched.
            let listed = Set(self.savedMessages.compactMap { musicFileId($0)?.id })
            if self.didReceiveSavedIds, let ids, ids != listed, !self.savedCanLoadMore {
                self.isReloadingSaved = true
                self.savedMusicContext.reload()
            }
            self.didReceiveSavedIds = true
        }))

        self.loadMoreChatMusic()

        self.sourcesDisposable.set((musicSourceSettings(context: context)
        |> deliverOnMainQueue).start(next: { [weak self] settings in
            guard let self else {
                return
            }
            let sourcePeerIds: Set<EnginePeer.Id>? = settings.allChats ? nil : Set(settings.chosenPeerIds)
            if sourcePeerIds != self.sourcePeerIds {
                self.sourcePeerIds = sourcePeerIds
                self.notifyUpdated()
            }
        }))

        self.fileListsDisposable.set((context.engine.data.get(
            TelegramEngine.EngineData.Item.ItemCache.Item(collectionId: ApplicationSpecificItemCacheCollectionId.music, id: MusicCacheKey.favorites.buffer),
            TelegramEngine.EngineData.Item.ItemCache.Item(collectionId: ApplicationSpecificItemCacheCollectionId.music, id: MusicCacheKey.removed.buffer)
        )
        |> deliverOnMainQueue).start(next: { [weak self] favorites, removed in
            guard let self else {
                return
            }
            self.favoriteFileIds.formUnion(favorites?.get(MusicFileIdList.self)?.fileIds ?? [])
            self.removedFileIds.formUnion(removed?.get(MusicFileIdList.self)?.fileIds ?? [])
            self.notifyUpdated()
        }))

        self.recentSearchesDisposable.set((context.engine.data.get(
            TelegramEngine.EngineData.Item.ItemCache.Item(collectionId: ApplicationSpecificItemCacheCollectionId.music, id: MusicCacheKey.recentSearches.buffer)
        )
        |> deliverOnMainQueue).start(next: { [weak self] entry in
            guard let self, let stored = entry?.get(MusicStoredRecentSearches.self) else {
                self?.didLoadRecentSearches = true
                return
            }
            // Anything opened before the list was read stays in front of it.
            self.recentSearchPlaylistIds = musicMergedRecents(self.recentSearchPlaylistIds, stored.playlistIds.map { Int($0) })
            self.recentSearchArtists = musicMergedRecents(self.recentSearchArtists, stored.artists)
            self.recentSearchFileIds = musicMergedRecents(self.recentSearchFileIds, stored.fileIds)
            self.didLoadRecentSearches = true
        }))

        self.addedFilesDisposable.set((context.engine.data.get(
            TelegramEngine.EngineData.Item.ItemCache.Item(collectionId: ApplicationSpecificItemCacheCollectionId.music, id: MusicCacheKey.addedFiles.buffer)
        )
        |> deliverOnMainQueue).start(next: { [weak self] entry in
            guard let self else {
                return
            }
            let addedMeanwhile = self.addedFiles
            self.addedFiles = (entry?.get(MusicStoredAddedFiles.self)?.files ?? []).compactMap { stored -> AddedFile? in
                guard let file = EnginePostboxDecoder(buffer: EngineMemoryBuffer(data: stored.data)).decodeRootObject() as? TelegramMediaFile else {
                    return nil
                }
                return AddedFile(file: file, timestamp: stored.timestamp)
            }
            for added in addedMeanwhile where !self.addedFiles.contains(where: { $0.file.fileId == added.file.fileId }) {
                self.addedFiles.append(added)
            }
            self.didLoadAddedFiles = true
            if !addedMeanwhile.isEmpty {
                self.storeAddedFiles()
            }
            self.notifyUpdated()
        }))

        self.trackEditsDisposable.set((context.engine.data.get(
            TelegramEngine.EngineData.Item.ItemCache.Item(collectionId: ApplicationSpecificItemCacheCollectionId.music, id: MusicCacheKey.trackEdits.buffer)
        )
        |> deliverOnMainQueue).start(next: { [weak self] entry in
            guard let self else {
                return
            }
            let editedMeanwhile = self.trackEdits
            for edit in entry?.get(MusicStoredTrackEdits.self)?.edits ?? [] {
                let cover = edit.cover.flatMap { cover in
                    return TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: cover.width, height: cover.height), resource: LocalFileMediaResource(fileId: cover.fileId), progressiveSizes: [], immediateThumbnailData: nil, hasVideo: false, isPersonal: false)
                }
                self.trackEdits[edit.fileId] = MusicTrackEdit(title: edit.title, artist: edit.artist, cover: cover)
            }
            for (fileId, edit) in editedMeanwhile {
                self.trackEdits[fileId] = edit
            }
            self.didLoadTrackEdits = true
            if !editedMeanwhile.isEmpty {
                self.storeTrackEdits()
            }
            self.notifyUpdated()
        }))

        self.profileDatesDisposable.set((context.engine.data.get(
            TelegramEngine.EngineData.Item.ItemCache.Item(collectionId: ApplicationSpecificItemCacheCollectionId.music, id: MusicCacheKey.profileDates.buffer)
        )
        |> deliverOnMainQueue).start(next: { [weak self] entry in
            guard let self else {
                return
            }
            let stored = entry?.get(MusicStoredProfileDates.self)
            let tracksMeanwhile = self.trackProfileDates
            let playlistsMeanwhile = self.playlistProfileDates
            for track in stored?.tracks ?? [] {
                self.trackProfileDates[track.fileId] = track.timestamp
            }
            for playlist in stored?.playlists ?? [] {
                self.playlistProfileDates[Int(playlist.id)] = playlist.timestamp
            }
            self.trackProfileDates.merge(tracksMeanwhile, uniquingKeysWith: { _, new in new })
            self.playlistProfileDates.merge(playlistsMeanwhile, uniquingKeysWith: { _, new in new })
            self.didLoadProfileDates = true
            if !tracksMeanwhile.isEmpty || !playlistsMeanwhile.isEmpty {
                self.storeProfileDates()
            }
            self.notifyUpdated()
        }))

        self.playlistsDisposable.set((context.engine.data.get(
            TelegramEngine.EngineData.Item.ItemCache.Item(collectionId: ApplicationSpecificItemCacheCollectionId.music, id: MusicCacheKey.playlists.buffer)
        )
        |> deliverOnMainQueue).start(next: { [weak self] entry in
            guard let self else {
                return
            }
            self.didLoadPlaylists = true
            guard let stored = entry?.get(MusicStoredPlaylists.self) else {
                if self.playlists.contains(where: { $0.id != 0 }) {
                    self.storePlaylists()
                }
                return
            }
            let createdMeanwhile = self.playlists.filter { $0.id != 0 }
            self.playlists = stored.playlists.map { playlist in
                let cover = playlist.cover.flatMap { cover in
                    return TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: cover.width, height: cover.height), resource: LocalFileMediaResource(fileId: cover.fileId), progressiveSizes: [], immediateThumbnailData: nil, hasVideo: false, isPersonal: false)
                }
                let coverMarkup = playlist.coverEmoji.flatMap { emoji -> TelegramMediaImage.EmojiMarkup in
                    if let packId = emoji.packId, let packAccessHash = emoji.packAccessHash {
                        return TelegramMediaImage.EmojiMarkup(content: .sticker(packReference: .id(id: packId, accessHash: packAccessHash), fileId: emoji.fileId), backgroundColors: emoji.backgroundColors)
                    }
                    return TelegramMediaImage.EmojiMarkup(content: .emoji(fileId: emoji.fileId), backgroundColors: emoji.backgroundColors)
                }
                self.pendingPlaylistFileIds[Int(playlist.id)] = playlist.fileIds
                return MusicPlaylist(id: Int(playlist.id), title: playlist.title, description: playlist.description, isFavorite: playlist.isFavorite, isInProfile: playlist.isInProfile, trackIds: [], cover: cover, coverMarkup: cover != nil ? coverMarkup : nil, dateAdded: playlist.dateAdded, dateUpdated: playlist.dateUpdated)
            }
            for var playlist in createdMeanwhile {
                playlist = MusicPlaylist(id: (self.playlists.map(\.id).max() ?? -1) + 1, title: playlist.title, description: playlist.description, isFavorite: playlist.isFavorite, isInProfile: playlist.isInProfile, trackIds: playlist.trackIds, cover: playlist.cover, coverMarkup: playlist.coverMarkup, dateAdded: playlist.dateAdded, dateUpdated: playlist.dateUpdated)
                self.playlists.append(playlist)
            }
            if !createdMeanwhile.isEmpty {
                self.storePlaylists()
            }
            self.notifyUpdated()
        }))
    }

    /// Turns stored files into the tracks now loaded, keeping each playlist's order.
    private func resolvePlaylistTracks() {
        guard !self.pendingPlaylistFileIds.isEmpty else {
            return
        }
        let messageIds = self.trackMessageIdsByFile()
        for (playlistId, fileIds) in self.pendingPlaylistFileIds {
            guard let index = self.playlists.firstIndex(where: { $0.id == playlistId }) else {
                self.pendingPlaylistFileIds[playlistId] = nil
                continue
            }
            if self.editedPlaylistIds.contains(playlistId) {
                var remaining: [MusicStoredPlaylists.FileId] = []
                for fileId in fileIds {
                    if let messageId = messageIds[fileId] {
                        if !self.playlists[index].trackIds.contains(messageId) {
                            self.playlists[index].trackIds.append(messageId)
                        }
                    } else {
                        remaining.append(fileId)
                    }
                }
                self.pendingPlaylistFileIds[playlistId] = remaining.isEmpty ? nil : remaining
            } else {
                // Untouched since launch: the stored order, as far as the music has loaded.
                let resolved = fileIds.compactMap { messageIds[$0] }
                if resolved != self.playlists[index].trackIds {
                    self.playlists[index].trackIds = resolved
                }
                if resolved.count == fileIds.count {
                    self.pendingPlaylistFileIds[playlistId] = nil
                }
            }
        }
    }

    /// A track whose row id changed (its file now listed from another source) keeps its place in playlists.
    private func followMovedTracks() {
        var current: [Int64: EngineMessage.Id] = [:]
        for track in self.allTracks {
            if let fileId = musicFileId(track.message), current[fileId.id] == nil {
                current[fileId.id] = track.message.id
                self.listedFileIdByMessageId[track.message.id] = MusicStoredPlaylists.FileId(namespace: fileId.namespace, id: fileId.id)
            }
        }
        var moved: [EngineMessage.Id: EngineMessage.Id] = [:]
        for (fileId, messageId) in current {
            if let previous = self.messageIdByFileId[fileId], previous != messageId {
                moved[previous] = messageId
            }
            self.messageIdByFileId[fileId] = messageId
        }
        guard !moved.isEmpty else {
            return
        }
        var didChange = false
        for index in self.playlists.indices {
            var trackIds: [EngineMessage.Id] = []
            for messageId in self.playlists[index].trackIds {
                let updated = moved[messageId] ?? messageId
                if !trackIds.contains(updated) {
                    trackIds.append(updated)
                }
            }
            if trackIds != self.playlists[index].trackIds {
                self.playlists[index].trackIds = trackIds
                didChange = true
            }
        }
        if didChange {
            self.storePlaylists()
        }
    }

    private func trackMessageIdsByFile() -> [MusicStoredPlaylists.FileId: EngineMessage.Id] {
        var messageIds: [MusicStoredPlaylists.FileId: EngineMessage.Id] = [:]
        for track in self.allTracks {
            if let fileId = musicFileId(track.message) {
                let key = MusicStoredPlaylists.FileId(namespace: fileId.namespace, id: fileId.id)
                if messageIds[key] == nil {
                    messageIds[key] = track.message.id
                }
            }
        }
        return messageIds
    }

    private func storePlaylists() {
        // Until the stored list has been read, a write would replace it.
        guard self.didLoadPlaylists else {
            return
        }
        var fileIds: [EngineMessage.Id: MusicStoredPlaylists.FileId] = [:]
        for track in self.allTracks {
            if let fileId = musicFileId(track.message) {
                fileIds[track.message.id] = MusicStoredPlaylists.FileId(namespace: fileId.namespace, id: fileId.id)
            }
        }
        // A track not listed now (its chat left out of the sources) keeps its file, so the playlist does not lose it.
        for (messageId, fileId) in self.listedFileIdByMessageId where fileIds[messageId] == nil {
            fileIds[messageId] = fileId
        }
        let stored = MusicStoredPlaylists(playlists: self.playlists.map { playlist in
            var playlistFileIds = playlist.trackIds.compactMap { fileIds[$0] }
            // Stored tracks the music has not loaded yet stay in the playlist.
            for fileId in self.pendingPlaylistFileIds[playlist.id] ?? [] where !playlistFileIds.contains(fileId) {
                playlistFileIds.append(fileId)
            }
            var cover: MusicStoredPlaylists.Cover?
            if let representation = playlist.cover, let resource = representation.resource as? LocalFileMediaResource {
                cover = MusicStoredPlaylists.Cover(fileId: resource.fileId, width: representation.dimensions.width, height: representation.dimensions.height)
            }
            var coverEmoji: MusicStoredPlaylists.CoverEmoji?
            if cover != nil, let markup = playlist.coverMarkup {
                switch markup.content {
                case let .emoji(fileId):
                    coverEmoji = MusicStoredPlaylists.CoverEmoji(fileId: fileId, packId: nil, packAccessHash: nil, backgroundColors: markup.backgroundColors)
                case let .sticker(packReference, fileId):
                    if case let .id(packId, packAccessHash) = packReference {
                        coverEmoji = MusicStoredPlaylists.CoverEmoji(fileId: fileId, packId: packId, packAccessHash: packAccessHash, backgroundColors: markup.backgroundColors)
                    }
                }
            }
            return MusicStoredPlaylists.Playlist(id: Int32(clamping: playlist.id), title: playlist.title, description: playlist.description, isFavorite: playlist.isFavorite, isInProfile: playlist.isInProfile, fileIds: playlistFileIds, cover: cover, coverEmoji: coverEmoji, dateAdded: playlist.dateAdded, dateUpdated: playlist.dateUpdated)
        })
        let _ = self.context.engine.itemCache.put(collectionId: ApplicationSpecificItemCacheCollectionId.music, id: MusicCacheKey.playlists.buffer, item: stored).startStandalone()
    }

    deinit {
        self.playingDisposable.dispose()
        self.savedDisposable.dispose()
        self.savedIdsDisposable.dispose()
        self.chatLoadDisposable.dispose()
        self.chatRefreshDisposable.dispose()
        self.uploadDisposables.dispose()
        self.fileListsDisposable.dispose()
        self.sourcesDisposable.dispose()
        self.removeAllDisposable.dispose()
        self.recentSearchesDisposable.dispose()
        self.playlistsDisposable.dispose()
        self.trackEditsDisposable.dispose()
        self.profileDatesDisposable.dispose()
    }

    // MARK: Playlists
    // They live as long as the library: the API has nowhere to keep them.

    func playlist(id: Int) -> MusicPlaylist? {
        return self.playlists.first(where: { $0.id == id })
    }

    @discardableResult
    func createPlaylist(title: String, description: String = "", trackIds: [EngineMessage.Id] = [], cover: TelegramMediaImageRepresentation? = nil, coverMarkup: TelegramMediaImage.EmojiMarkup? = nil) -> MusicPlaylist {
        let now = Int32(Date().timeIntervalSince1970)
        let playlist = MusicPlaylist(id: (self.playlists.map(\.id).max() ?? -1) + 1, title: title, description: description, isFavorite: false, trackIds: trackIds, cover: cover, coverMarkup: coverMarkup, dateAdded: now, dateUpdated: now)
        self.playlists.append(playlist)
        self.storePlaylists()
        self.notifyUpdated()
        return playlist
    }

    func updatePlaylist(id: Int, _ f: (inout MusicPlaylist) -> Void) {
        guard let index = self.playlists.firstIndex(where: { $0.id == id }) else {
            return
        }
        var playlist = self.playlists[index]
        f(&playlist)
        if playlist != self.playlists[index] {
            playlist.dateUpdated = Int32(Date().timeIntervalSince1970)
            if playlist.trackIds != self.playlists[index].trackIds, let pending = self.pendingPlaylistFileIds[id] {
                // An edit of the list replaces it; stored tracks still loading join its end when they arrive.
                let loaded = self.trackMessageIdsByFile()
                self.pendingPlaylistFileIds[id] = pending.filter { loaded[$0] == nil }
                self.editedPlaylistIds.insert(id)
            }
            self.playlists[index] = playlist
            self.storePlaylists()
            self.notifyUpdated()
        }
    }

    func removePlaylist(id: Int) {
        self.playlists.removeAll(where: { $0.id == id })
        self.pendingPlaylistFileIds[id] = nil
        self.storePlaylists()
        self.notifyUpdated()
    }

    func add(tracks: [MusicTrack], to playlistId: Int) {
        self.updatePlaylist(id: playlistId, { playlist in
            for track in tracks where !playlist.trackIds.contains(track.message.id) {
                playlist.trackIds.append(track.message.id)
            }
        })
    }

    /// Tracks in the playlist's own order; a track that left the music leaves the playlist's list too.
    func tracks(of playlist: MusicPlaylist) -> [MusicTrack] {
        let tracks = self.allTracks
        var byId: [EngineMessage.Id: MusicTrack] = [:]
        for track in tracks {
            byId[track.message.id] = track
        }
        return playlist.trackIds.compactMap { byId[$0] }
    }

    func playlists(sorting: MusicSorting) -> [MusicPlaylist] {
        let isOrdered: (MusicPlaylist, MusicPlaylist) -> Bool
        switch sorting.key {
        case .title, .artist:
            isOrdered = { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .dateAdded, .lastPlayed, .playlistOrder:
            isOrdered = { $0.dateAdded < $1.dateAdded || ($0.dateAdded == $1.dateAdded && $0.id < $1.id) }
        case .dateUpdated:
            isOrdered = { $0.dateUpdated < $1.dateUpdated || ($0.dateUpdated == $1.dateUpdated && $0.id < $1.id) }
        }
        return self.playlists.sorted { sorting.ascending ? isOrdered($0, $1) : isOrdered($1, $0) }
    }

    // MARK: Recent searches

    func noteSearched(playlist: MusicPlaylist) {
        self.recentSearchPlaylistIds = musicMergedRecents([playlist.id], self.recentSearchPlaylistIds)
        self.storeRecentSearches()
    }

    func noteSearched(artist: MusicArtist) {
        self.recentSearchArtists = musicMergedRecents([artist.name.lowercased()], self.recentSearchArtists)
        self.storeRecentSearches()
    }

    func noteSearched(track: MusicTrack) {
        guard let fileId = track.file?.fileId.id else {
            return
        }
        self.recentSearchFileIds = musicMergedRecents([fileId], self.recentSearchFileIds)
        self.storeRecentSearches()
    }

    private func storeRecentSearches() {
        guard self.didLoadRecentSearches else {
            return
        }
        let item = MusicStoredRecentSearches(playlistIds: self.recentSearchPlaylistIds.map { Int32(clamping: $0) }, artists: self.recentSearchArtists, fileIds: self.recentSearchFileIds)
        let _ = self.context.engine.itemCache.put(collectionId: ApplicationSpecificItemCacheCollectionId.music, id: MusicCacheKey.recentSearches.buffer, item: item).startStandalone()
    }

    func isFavorite(_ track: MusicTrack) -> Bool {
        guard let fileId = track.file?.fileId.id else {
            return false
        }
        return self.favoriteFileIds.contains(fileId)
    }

    func setFavorite(_ track: MusicTrack, _ isFavorite: Bool) {
        guard let fileId = track.file?.fileId.id else {
            return
        }
        self.setFavorite(fileId: fileId, isFavorite)
    }

    func setFavorite(fileId: Int64, _ isFavorite: Bool) {
        if isFavorite {
            self.favoriteFileIds.insert(fileId)
        } else {
            self.favoriteFileIds.remove(fileId)
        }
        self.storeFileIds(self.favoriteFileIds, key: .favorites)
        self.notifyUpdated()
    }

    /// Takes the tracks out of Music only: the profile and the chats keep their files (Music and the profile are
    /// separate; the track menu has its own profile action).
    func remove(tracks: [MusicTrack]) {
        var removedAdded = false
        for track in tracks {
            guard let file = track.file else {
                continue
            }
            let fileId = file.fileId.id
            self.favoriteFileIds.remove(fileId)
            self.removedFileIds.insert(fileId)
            if let index = self.addedFiles.firstIndex(where: { $0.file.fileId.id == fileId }) {
                self.addedFiles.remove(at: index)
                removedAdded = true
            }
        }
        self.storeFileIds(self.favoriteFileIds, key: .favorites)
        self.storeFileIds(self.removedFileIds, key: .removed)
        if removedAdded {
            self.storeAddedFiles()
        }
        self.notifyUpdated()
    }

    /// Empties Music: the playlists go, the chosen source chats are reset to none, and every track that is not only
    /// a chat's is taken out (the profile and the chats keep their files). Chat audio is left alone: with no source
    /// chats none of it is listed, and choosing a chat again brings its music back.
    /// The profile's music still loading is taken out once it has arrived; files that come later enter Music as usual.
    func removeAll() {
        setMusicSourceSettings(context: self.context, MusicSourceSettings(allChats: false, peerIds: []))
        // Applied here too: the stored setting reaches the subscription a moment later.
        self.sourcePeerIds = Set()
        let apply: () -> Void = { [weak self] in
            guard let self else {
                return
            }
            let chatFileIds = Set(self.chatMessages.compactMap { musicFileId($0)?.id })
            let tracks = self.allTracks.filter { track in
                guard let fileId = track.file?.fileId.id else {
                    return true
                }
                return track.isSaved || !chatFileIds.contains(fileId)
            }
            if !tracks.isEmpty {
                self.remove(tracks: tracks)
            } else {
                self.notifyUpdated()
            }
            if !self.playlists.isEmpty {
                for playlist in self.playlists {
                    self.pendingPlaylistFileIds[playlist.id] = nil
                }
                self.playlists = []
                self.storePlaylists()
                self.notifyUpdated()
            }
        }
        apply()
        if self.isFullyLoaded {
            self.removeAllDisposable.set(nil)
            return
        }
        self.removeAllDisposable.set(self.updated.signal().start(next: { [weak self] _ in
            guard let self, self.isFullyLoaded else {
                return
            }
            self.removeAllDisposable.set(nil)
            apply()
        }))
    }

    /// The profile's files, as the account's saved-music ids report them. The player saves through other contexts;
    /// these ids are what every menu reads, so the player's change shows here at once.
    private(set) var savedFileIds: Set<Int64>? {
        didSet { self.cachedAllTracks = nil }
    }

    func isSavedToProfile(_ track: MusicTrack) -> Bool {
        guard let fileId = track.file?.fileId.id, let savedFileIds = self.savedFileIds else {
            return track.isSaved
        }
        return savedFileIds.contains(fileId)
    }

    /// Adds a chat's track to the profile, or takes a saved one off it.
    func setSavedToProfile(_ track: MusicTrack, _ isSaved: Bool) {
        guard let file = track.file else {
            return
        }
        if var savedFileIds = self.savedFileIds {
            if isSaved {
                savedFileIds.insert(file.fileId.id)
            } else {
                savedFileIds.remove(file.fileId.id)
            }
            self.savedFileIds = savedFileIds
        }
        // The profile's list is updated at once, so the track keeps its place in Music.
        let reference: FileMediaReference = track.message.id.namespace == Namespaces.Message.Local ? .standalone(media: file) : .message(message: MessageReference(track.message), media: file)
        if isSaved {
            self.stampProfileDates(fileIds: [file.fileId.id])
            let _ = self.savedMusicContext.addMusic(file: reference).startStandalone()
        } else {
            self.keepInMusic(fileIds: [file.fileId.id])
            let _ = self.savedMusicContext.removeMusic(file: .standalone(media: file)).startStandalone()
        }
        self.notifyUpdated()
    }

    // MARK: Profile
    // The profile's music: its saved tracks (server) and the playlists put there (local stand-ins).

    private func stampProfileDates(fileIds: Set<Int64>) {
        guard !fileIds.isEmpty else {
            return
        }
        let now = Int32(Date().timeIntervalSince1970)
        for fileId in fileIds {
            self.trackProfileDates[fileId] = now
        }
        self.storeProfileDates()
    }

    private func storeProfileDates() {
        guard self.didLoadProfileDates else {
            return
        }
        let item = MusicStoredProfileDates(
            tracks: self.trackProfileDates.map { MusicStoredProfileDates.Track(fileId: $0.key, timestamp: $0.value) },
            playlists: self.playlistProfileDates.map { MusicStoredProfileDates.Playlist(id: Int32(clamping: $0.key), timestamp: $0.value) }
        )
        let _ = self.context.engine.itemCache.put(collectionId: ApplicationSpecificItemCacheCollectionId.music, id: MusicCacheKey.profileDates.buffer, item: item).startStandalone()
    }

    /// The profile's tracks, last put there first. A track also in Music is its Music row, so menus and favorites
    /// work on it; a track taken out of Music stays in the profile as the profile lists it.
    var profileTracks: [MusicTrack] {
        let byFileId = self.allTracksCache().byFileId
        var fileIds = Set<Int64>()
        var tracks: [(track: MusicTrack, date: Int32)] = []
        for message in self.savedMessages {
            guard let fileId = musicFileId(message)?.id, fileIds.insert(fileId).inserted else {
                continue
            }
            if let savedFileIds = self.savedFileIds, !savedFileIds.contains(fileId) {
                continue
            }
            let track = byFileId[fileId] ?? MusicTrack(message: self.applyingEdit(message), isSaved: true)
            tracks.append((track, self.trackProfileDates[fileId] ?? 0))
        }
        // The profile lists its newest first already; a date known here only moves tracks put in from this device.
        return tracks.enumerated().sorted { lhs, rhs in
            if lhs.element.date != rhs.element.date {
                return lhs.element.date > rhs.element.date
            }
            return lhs.offset < rhs.offset
        }.map(\.element.track)
    }

    /// Playlists put in the profile, last put there first.
    var profilePlaylists: [MusicPlaylist] {
        return self.playlists.filter(\.isInProfile).sorted { lhs, rhs in
            let lhsDate = self.playlistProfileDates[lhs.id] ?? 0
            let rhsDate = self.playlistProfileDates[rhs.id] ?? 0
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.dateAdded > rhs.dateAdded
        }
    }

    var hasProfileMusic: Bool {
        return !self.profileTracks.isEmpty || !self.profilePlaylists.isEmpty
    }

    func setPlaylistInProfile(id: Int, _ isInProfile: Bool) {
        if isInProfile {
            self.playlistProfileDates[id] = Int32(Date().timeIntervalSince1970)
        } else {
            self.playlistProfileDates[id] = nil
        }
        self.storeProfileDates()
        self.updatePlaylist(id: id, { playlist in
            playlist.isInProfile = isInProfile
        })
    }

    /// The local test user's profile music (concept only): the five newest tracks of this library and one of its
    /// playlists, so another user's profile can be shown with music in it.
    func testProfileContent() -> (tracks: [MusicTrack], playlists: [MusicPlaylist]) {
        let tracks = Array(self.tracks(source: .all, sorting: MusicSorting(key: .dateAdded, ascending: false)).prefix(5))
        let playlists = self.playlists(sorting: MusicSorting(key: .dateAdded, ascending: false))
        let playlist = playlists.first(where: { !self.tracks(of: $0).isEmpty }) ?? playlists.first
        return (tracks, playlist.flatMap { [$0] } ?? [])
    }

    func testProfileSummary(strings: PresentationStrings) -> MusicProfileSummary? {
        let content = self.testProfileContent()
        if let track = content.tracks.first {
            return MusicProfileSummary(title: track.title, subtitle: track.artist ?? strings.MediaPlayer_UnknownArtist)
        }
        if let playlist = content.playlists.first {
            return MusicProfileSummary(title: playlist.title, subtitle: musicTrackCountString(strings, self.tracks(of: playlist).count))
        }
        return nil
    }

    func profileSummary(strings: PresentationStrings) -> MusicProfileSummary? {
        if let track = self.profileTracks.first {
            return MusicProfileSummary(title: track.title, subtitle: track.artist ?? strings.MediaPlayer_UnknownArtist)
        }
        if let playlist = self.profilePlaylists.first {
            return MusicProfileSummary(title: playlist.title, subtitle: musicTrackCountString(strings, self.tracks(of: playlist).count))
        }
        return nil
    }

    private func storeFileIds(_ fileIds: Set<Int64>, key: MusicCacheKey) {
        let _ = self.context.engine.itemCache.put(collectionId: ApplicationSpecificItemCacheCollectionId.music, id: key.buffer, item: MusicFileIdList(fileIds: Array(fileIds))).startStandalone()
    }

    private func loadMoreChatMusic() {
        guard self.chatCanLoadMore, !self.isLoadingChatMessages else {
            return
        }
        self.isLoadingChatMessages = true
        self.chatLoadDisposable.set((self.chatMusicSearch(state: self.chatSearchState)
        |> deliverOnMainQueue).start(next: { [weak self] result, state in
            guard let self else {
                return
            }
            self.isLoadingChatMessages = false
            self.chatMessages = result.messages
            self.chatSearchState = state
            self.chatCanLoadMore = !result.completed
            self.notifyUpdated()
            self.loadMoreChatMusic()
        }))
    }

    /// Puts tracks that arrived in chats since the last load on top, keeping the pages already loaded.
    func refreshChatMusic() {
        guard self.chatSearchState != nil else {
            return
        }
        self.chatRefreshDisposable.set((self.chatMusicSearch(state: nil)
        |> deliverOnMainQueue).start(next: { [weak self] result, _ in
            guard let self else {
                return
            }
            let knownIds = Set(self.chatMessages.map(\.id))
            let newMessages = result.messages.filter { !knownIds.contains($0.id) }
            if !newMessages.isEmpty {
                self.chatMessages = newMessages + self.chatMessages
                self.notifyUpdated()
            }
        }))
    }

    func tracks(source: MusicTrackSource, sorting: MusicSorting) -> [MusicTrack] {
        var tracks = self.allTracks
        switch source {
        case .all:
            break
        case let .artist(artist):
            let artist = artist.lowercased()
            tracks = tracks.filter { $0.artist?.lowercased() == artist }
        case .favorites:
            tracks = tracks.filter { self.isFavorite($0) }
        case let .playlist(id):
            tracks = self.playlist(id: id).flatMap { self.tracks(of: $0) } ?? []
            if sorting.key == .playlistOrder {
                return sorting.ascending ? tracks : tracks.reversed()
            }
        }
        let isOrdered: (MusicTrack, MusicTrack) -> Bool
        switch sorting.key {
        case .artist:
            isOrdered = {
                let result = ($0.artist ?? "").localizedStandardCompare($1.artist ?? "")
                if result != .orderedSame {
                    return result == .orderedAscending
                }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .dateAdded, .lastPlayed, .dateUpdated, .playlistOrder:
            isOrdered = { $0.message.timestamp < $1.message.timestamp }
        case .title:
            isOrdered = { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return tracks.sorted { sorting.ascending ? isOrdered($0, $1) : isOrdered($1, $0) }
    }

    /// Reads a picked audio file into a local file: its tags and artwork prefill the new track screen.
    func prepareTrack(url: URL) -> Signal<TelegramMediaFile?, NoError> {
        return iCloudFileDescription(url)
        |> map { item -> TelegramMediaFile? in
            guard let item else {
                return nil
            }
            let mimeType = guessMimeTypeByFileExtension((item.fileName as NSString).pathExtension)
            var previewRepresentations: [TelegramMediaImageRepresentation] = []
            if item.audioMetadata?.hasAudioArtwork == true {
                previewRepresentations.append(TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 320, height: 320), resource: ICloudFileResource(urlData: item.urlData, thumbnail: true), progressiveSizes: [], immediateThumbnailData: nil, hasVideo: false, isPersonal: false))
            }
            var attributes: [TelegramMediaFileAttribute] = [.FileName(fileName: item.fileName)]
            if let audioMetadata = item.audioMetadata {
                attributes.append(.Audio(isVoice: false, duration: audioMetadata.duration, title: audioMetadata.title, performer: audioMetadata.performer, waveform: nil))
            }
            return TelegramMediaFile(fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: Int64.random(in: Int64.min ... Int64.max)), partialReference: nil, resource: ICloudFileResource(urlData: item.urlData, thumbnail: false), previewRepresentations: previewRepresentations, videoThumbnails: [], immediateThumbnailData: nil, mimeType: mimeType, size: Int64(item.fileSize), attributes: attributes, alternativeRepresentations: [])
        }
        |> deliverOnMainQueue
    }

    /// Uploads a prepared audio file with the title, artist and cover from the new track screen and saves it to the profile,
    /// as the music player's Add does. A picked cover goes up as the file's thumbnail.
    func addTrack(file preparedFile: TelegramMediaFile, title: String, artist: String, coverData: Data?, completion: @escaping (Bool) -> Void) {
        let context = self.context
        var file = musicFile(preparedFile, title: title, artist: artist, cover: nil)
        if coverData != nil {
            file = file.withUpdatedPreviewRepresentations([])
        }
        let uploadDisposable = MetaDisposable()
        self.uploadDisposables.add(uploadDisposable)
        uploadDisposable.set((standaloneUploadedFile(
            postbox: context.account.postbox,
            network: context.account.network,
            peerId: context.account.peerId,
            text: "",
            source: .resource(.media(media: .standalone(media: file), resource: file.resource)),
            thumbnailData: coverData ?? file.immediateThumbnailData,
            mimeType: file.mimeType,
            attributes: file.attributes,
            hintFileIsLarge: false
        )
        |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self, case let .result(result) = value, case let .media(resultMedia) = result, let resultFile = resultMedia.media as? TelegramMediaFile else {
                return
            }
            context.engine.resources.moveResourceData(from: EngineMediaResource.Id(file.resource.id), to: EngineMediaResource.Id(resultFile.resource.id), synchronous: true)
            uploadDisposable.set((context.engine.peers.addSavedMusic(file: .standalone(media: resultFile))
            |> deliverOnMainQueue).start(error: { [weak self] _ in
                self?.uploadDisposables.remove(uploadDisposable)
                completion(false)
            }, completed: { [weak self] in
                self?.uploadDisposables.remove(uploadDisposable)
                completion(true)
            }))
        }, error: { [weak self] _ in
            self?.uploadDisposables.remove(uploadDisposable)
            completion(false)
        }))
    }

    /// Plays in the order of the list the track was started from. The player reads the queue again at every
    /// track change, so editing it while it plays changes what comes next.
    func playlistLocation(track: MusicTrack, tracks: [MusicTrack], title: String, kind: MusicPlayerQueueKind, source: (() -> [MusicTrack]?)? = nil) -> PeerMessagesPlaylistLocation {
        self.queue = tracks.map(\.message)
        self.queueTitle = title
        self.queueKind = kind
        self.queueIsReversed = false
        self.queueIsShuffled = false
        self.queueOrderBeforeShuffle = nil
        self.queueSource = source
        self.queueIsCustomized = false
        self.playingMessageId = track.message.id
        self.watchPlayingTrack()
        self.queuePromise.set(.single(self.queue))
        self.queueInfo.set(MusicPlayerQueueInfo(messageIds: self.queue.map(\.id), title: title, kind: kind, isReversed: false, isShuffled: false))
        return self.queueLocation(at: track.message.id)
    }

    /// The current queue, restarted at one of its tracks: the player sheet's queue list plays from it.
    func queueLocation(at messageId: EngineMessage.Id) -> PeerMessagesPlaylistLocation {
        let queue = self.queuePromise.get()
        |> map { messages -> ([EngineRawMessage], Int32, Bool) in
            return (messages, Int32(messages.count), false)
        }
        return .custom(messages: queue, canReorder: false, at: messageId, loadMore: nil, hidePanel: false)
    }

    /// The queue's tracks in play order, now and after every edit.
    var queueMessages: Signal<[EngineRawMessage], NoError> {
        return self.queuePromise.get()
    }

    /// Reverse turns the queue over in place: the player reads it again at the next track, so what plays after the
    /// current track becomes what played before it. Shuffle is a separate setting and keeps working on top.
    func setQueueReversed(_ isReversed: Bool) {
        guard self.queueIsReversed != isReversed else {
            return
        }
        self.queueIsReversed = isReversed
        self.queue.reverse()
        self.queuePromise.set(.single(self.queue))
        self.queueInfo.set(MusicPlayerQueueInfo(messageIds: self.queue.map(\.id), title: self.queueTitle, kind: self.queueKind, isReversed: isReversed, isShuffled: self.queueIsShuffled))
    }

    /// Shuffle mixes the queue in place, Apple Music style: the playing track comes first and the rest follow in a
    /// random order, which the queue list shows and lets the user drag. Turning it off brings the order back from
    /// before Shuffle, the playing track where it was; tracks that joined meanwhile keep their order at the end.
    func setQueueShuffled(_ isShuffled: Bool) {
        guard self.queueIsShuffled != isShuffled, !self.queue.isEmpty else {
            return
        }
        var queue = self.queue
        if isShuffled {
            self.queueOrderBeforeShuffle = (queue.map(\.id), self.queueIsReversed, self.queueIsCustomized)
            var rest = queue
            var head: [EngineRawMessage] = []
            if let playingId = self.playingMessageId, let index = rest.firstIndex(where: { $0.id == playingId }) {
                head.append(rest.remove(at: index))
            }
            rest.shuffle()
            queue = head + rest
        } else {
            if let before = self.queueOrderBeforeShuffle {
                var ids = before.ids
                if before.isReversed != self.queueIsReversed {
                    ids.reverse()
                }
                var position: [EngineMessage.Id: Int] = [:]
                for (index, id) in ids.enumerated() {
                    position[id] = index
                }
                let known = queue.filter { position[$0.id] != nil }.sorted(by: { position[$0.id]! < position[$1.id]! })
                let added = queue.filter { position[$0.id] == nil }
                queue = known + added
                self.queueIsCustomized = before.isCustomized || !added.isEmpty
            }
            self.queueOrderBeforeShuffle = nil
        }
        self.queueIsShuffled = isShuffled
        self.queue = queue
        self.queuePromise.set(.single(queue))
        self.queueInfo.set(MusicPlayerQueueInfo(messageIds: queue.map(\.id), title: self.queueTitle, kind: self.queueKind, isReversed: self.queueIsReversed, isShuffled: isShuffled))
    }

    /// Moves a track of the queue to another place, as the player sheet's list is reordered.
    func moveInQueue(messageId: EngineMessage.Id, toIndex: Int) {
        guard let fromIndex = self.queue.firstIndex(where: { $0.id == messageId }) else {
            return
        }
        var queue = self.queue
        let message = queue.remove(at: fromIndex)
        queue.insert(message, at: max(0, min(queue.count, toIndex)))
        guard queue.map(\.id) != self.queue.map(\.id) else {
            return
        }
        self.queueIsCustomized = true
        self.queue = queue
        self.queuePromise.set(.single(queue))
        self.queueInfo.set(MusicPlayerQueueInfo(messageIds: queue.map(\.id), title: self.queueTitle, kind: self.queueKind, isReversed: self.queueIsReversed, isShuffled: self.queueIsShuffled))
    }

    /// Puts the tracks right after the playing one, or at the end of the queue, in their order.
    /// Completes with false when nothing from this section is playing: there is no queue to edit.
    func enqueue(tracks: [MusicTrack], next: Bool, completion: @escaping (Bool) -> Void) {
        let _ = (self.context.sharedContext.mediaManager.musicMediaPlayerState
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let self, let state, case let .state(itemState) = state.1, let itemId = itemState.item.id as? PeerMessagesMediaPlaylistItemId, let currentIndex = self.queue.firstIndex(where: { $0.id == itemId.messageId }) else {
                completion(false)
                return
            }
            var queue = self.queue
            let currentId = queue[currentIndex].id
            let messages = tracks.map(\.message).filter { $0.id != currentId }
            let movedIds = Set(messages.map(\.id))
            queue.removeAll(where: { movedIds.contains($0.id) })
            if next, let index = queue.firstIndex(where: { $0.id == currentId }) {
                queue.insert(contentsOf: messages, at: index + 1)
            } else {
                queue.append(contentsOf: messages)
            }
            self.queueIsCustomized = true
            self.queue = queue
            self.queuePromise.set(.single(queue))
            self.queueInfo.set(MusicPlayerQueueInfo(messageIds: queue.map(\.id), title: self.queueTitle, kind: self.queueKind, isReversed: self.queueIsReversed, isShuffled: self.queueIsShuffled))
            completion(true)
        })
    }

    private func chatMusicSearch(state: SearchMessagesState?) -> Signal<(SearchMessagesResult, SearchMessagesState), NoError> {
        // The local test chat is a place to look at tracks in bubbles, not a source of Music.
        return self.context.engine.messages.searchMessages(location: .general(scope: .everywhere, groupId: nil, tags: [.music], minDate: nil, maxDate: nil, folderId: nil, communityId: nil), query: "", state: state)
        |> map { result, state -> (SearchMessagesResult, SearchMessagesState) in
            let messages = result.messages.filter { $0.id.peerId != musicTestChatPeerId }
            if messages.count == result.messages.count {
                return (result, state)
            }
            return (SearchMessagesResult(messages: messages, readStates: result.readStates, threadInfo: result.threadInfo, totalCount: result.totalCount - Int32(result.messages.count - messages.count), completed: result.completed), state)
        }
    }

    /// The favorite files, now and after every change.
    var favoriteFileIdsSignal: Signal<Set<Int64>, NoError> {
        return Signal { [weak self] subscriber in
            guard let self else {
                subscriber.putCompletion()
                return EmptyDisposable
            }
            subscriber.putNext(self.favoriteFileIds)
            return self.updated.signal().start(next: { [weak self] _ in
                if let self {
                    subscriber.putNext(self.favoriteFileIds)
                }
            })
        }
        |> runOn(Queue.mainQueue())
        |> distinctUntilChanged
    }

    /// What the player sheet needs to tell whether a file is in Music: favorites, files taken out, files loaded.
    var playerStateSignal: Signal<MusicPlayerLibraryState, NoError> {
        return Signal { [weak self] subscriber in
            guard let self else {
                subscriber.putCompletion()
                return EmptyDisposable
            }
            let state: () -> MusicPlayerLibraryState = { [weak self] in
                guard let self else {
                    return MusicPlayerLibraryState(favoriteFileIds: [], removedFileIds: [], trackFileIds: [])
                }
                return MusicPlayerLibraryState(favoriteFileIds: self.favoriteFileIds, removedFileIds: self.removedFileIds, trackFileIds: Set(self.allTracksCache().byFileId.keys))
            }
            subscriber.putNext(state())
            return self.updated.signal().start(next: { _ in
                subscriber.putNext(state())
            })
        }
        |> runOn(Queue.mainQueue())
        |> distinctUntilChanged
    }

    /// Files in Music per account, as last published: chat bubbles read it while laying out, off the main queue.
    private static let fileIdsSnapshot = Atomic<[AccountRecordId: Set<Int64>]>(value: [:])

    /// The same set for every subscriber: chat bubbles each watch it, so it is built once per change, not per bubble.
    private let fileIdsValue = ValuePromise<Set<Int64>>(Set(), ignoreRepeated: true)

    private func publishFileIds() {
        let fileIds = Set(self.allTracksCache().byFileId.keys)
        self.fileIdsValue.set(fileIds)
        let accountId = self.context.account.id
        let _ = MusicLibrary.fileIdsSnapshot.modify { current in
            var current = current
            current[accountId] = fileIds
            return current
        }
    }

    /// Whether the file is in Music, from any queue. False until the library has been created.
    static func containsFile(accountId: AccountRecordId, fileId: Int64) -> Bool {
        return MusicLibrary.fileIdsSnapshot.with { $0[accountId]?.contains(fileId) ?? false }
    }

    /// The files in Music, now and after every change.
    var fileIdsSignal: Signal<Set<Int64>, NoError> {
        self.publishFileIds()
        return self.fileIdsValue.get()
    }

    /// The loaded track that holds this file.
    func track(fileId: Int64) -> MusicTrack? {
        return self.allTracksCache().byFileId[fileId]
    }

    private func notifyUpdated() {
        self.followMovedTracks()
        self.resolvePlaylistTracks()
        self.publishFileIds()
        self.updated.putNext(Void())
        // After the screens: the list the queue came from has just been rebuilt by them.
        self.syncQueueWithLibrary()
    }

    /// The track the player is on, so syncing never drops it from under the player.
    private func watchPlayingTrack() {
        self.playingDisposable.set((self.context.sharedContext.mediaManager.musicMediaPlayerState
        |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let self, let state, case let .state(itemState) = state.1, let itemId = itemState.item.id as? PeerMessagesMediaPlaylistItemId else {
                return
            }
            self.playingMessageId = itemId.messageId
        }))
    }

    /// Keeps the queue to the library as it is now: an edited track shows its new title and cover, a track taken out
    /// of Music leaves the queue, and tracks that joined the source list (chat audio loads page by page) join it in
    /// its order. A queue whose order was changed by hand keeps that order; new tracks go to its end.
    private func syncQueueWithLibrary() {
        guard !self.queue.isEmpty else {
            return
        }
        // Rows are matched by file as well as by id: profile and device tracks get new local ids when their lists
        // reload, while the player keeps the message it started with.
        var tracksById: [EngineMessage.Id: EngineRawMessage] = [:]
        var tracksByFileId: [Int64: EngineRawMessage] = [:]
        for track in self.allTracks {
            tracksById[track.message.id] = track.message
            if let fileId = musicFileId(track.message)?.id {
                tracksByFileId[fileId] = track.message
            }
        }
        let removedFileIds = self.removedFileIds
        let playingId = self.playingMessageId
        // The playing message stays exactly as the player has it, so Next finds it in the queue.
        let playingMessage = playingId.flatMap { id in self.queue.first(where: { $0.id == id }) }
        let playingFileId = playingMessage.flatMap { musicFileId($0)?.id }
        let resolve: (EngineRawMessage) -> EngineRawMessage = { message in
            if let playingMessage, message.id == playingMessage.id || (playingFileId != nil && musicFileId(message)?.id == playingFileId) {
                return playingMessage
            }
            if let current = tracksById[message.id] {
                return current
            }
            if let fileId = musicFileId(message)?.id, let current = tracksByFileId[fileId] {
                return current
            }
            return message
        }
        let isKept: (EngineRawMessage) -> Bool = { message in
            if message.id == playingId {
                return true
            }
            guard let fileId = musicFileId(message)?.id else {
                return true
            }
            return !removedFileIds.contains(fileId)
        }

        var updated: [EngineRawMessage]
        let source = self.queueSource?().flatMap { $0.isEmpty ? nil : $0 }
        if let source, !self.queueIsCustomized, !self.queueIsShuffled {
            updated = source.map { resolve($0.message) }
            if self.queueIsReversed {
                updated.reverse()
            }
            if let playingMessage, !updated.contains(where: { $0.id == playingMessage.id }), let index = self.queue.firstIndex(where: { $0.id == playingMessage.id }) {
                updated.insert(playingMessage, at: min(index, updated.count))
            }
        } else {
            updated = self.queue.filter(isKept).map(resolve)
            if let source {
                let knownIds = Set(updated.map(\.id))
                let knownFileIds = Set(updated.compactMap { musicFileId($0)?.id })
                let added = source.map(\.message).filter { message in
                    if knownIds.contains(message.id) {
                        return false
                    }
                    if let fileId = musicFileId(message)?.id, knownFileIds.contains(fileId) {
                        return false
                    }
                    return true
                }
                updated.append(contentsOf: self.queueIsReversed ? added.reversed() : added)
            }
        }

        var seenIds = Set<EngineMessage.Id>()
        updated = updated.filter { seenIds.insert($0.id).inserted }
        let changed = updated.count != self.queue.count || zip(updated, self.queue).contains(where: { $0.id != $1.id || $0 !== $1 })
        guard changed else {
            return
        }
        self.queue = updated
        self.queuePromise.set(.single(updated))
        self.queueInfo.set(MusicPlayerQueueInfo(messageIds: updated.map(\.id), title: self.queueTitle, kind: self.queueKind, isReversed: self.queueIsReversed, isShuffled: self.queueIsShuffled))
    }
}

/// The file with its audio title and performer replaced, and its cover when one is given.
func musicFile(_ file: TelegramMediaFile, title: String, artist: String, cover: TelegramMediaImageRepresentation?) -> TelegramMediaFile {
    var attributes = file.attributes
    let title: String? = title.isEmpty ? nil : title
    let performer: String? = artist.isEmpty ? nil : artist
    if let index = attributes.firstIndex(where: { if case .Audio = $0 { return true } else { return false } }), case let .Audio(isVoice, duration, _, _, waveform) = attributes[index] {
        attributes[index] = .Audio(isVoice: isVoice, duration: duration, title: title, performer: performer, waveform: waveform)
    } else {
        attributes.append(.Audio(isVoice: false, duration: 0, title: title, performer: performer, waveform: nil))
    }
    var result = file.withUpdatedAttributes(attributes)
    if let cover {
        result = result.withUpdatedPreviewRepresentations([cover])
    }
    return result
}

private func musicFileId(_ message: EngineRawMessage) -> EngineMedia.Id? {
    for media in message.media {
        if let file = media as? TelegramMediaFile {
            return file.fileId
        }
    }
    return nil
}

/// `front` before `rest`, without repeats, at most 50.
private func musicMergedRecents<T: Hashable>(_ front: [T], _ rest: [T]) -> [T] {
    var seen = Set<T>()
    var result: [T] = []
    for value in front + rest where seen.insert(value).inserted {
        result.append(value)
        if result.count == 50 {
            break
        }
    }
    return result
}
