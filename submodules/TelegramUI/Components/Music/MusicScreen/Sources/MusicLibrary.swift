import Foundation
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramUIPreferences
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
        let dateAdded: Int32
        let dateUpdated: Int32
    }

    let playlists: [Playlist]
}

/// The section's local state shares one item cache collection, one entry per kind.
private enum MusicCacheKey: Int32 {
    // 0 held play counts, which nothing reads any more.
    case favorites = 1
    case removed = 2
    case tabSettings = 3
    case playlists = 4

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

/// The account's music: the tracks saved to its profile and the audio files of all its chats.
/// Both are real server data; a track found in several places is listed once, saved first.
/// Sorting and artists need the whole list, so every page is loaded up front.
/// The section's screens share one library.
final class MusicLibrary {
    private let context: AccountContext
    private let savedMusicContext: ProfileSavedMusicContext

    private var savedMessages: [EngineRawMessage] = []
    private var savedCanLoadMore = false
    private var didReceiveSavedIds = false
    private var chatMessages: [EngineRawMessage] = []
    private var chatSearchState: SearchMessagesState?
    private var chatCanLoadMore = true
    private var isLoadingChatMessages = false

    private let savedDisposable = MetaDisposable()
    private let savedIdsDisposable = MetaDisposable()
    private let chatLoadDisposable = MetaDisposable()
    private let chatRefreshDisposable = MetaDisposable()
    private let uploadDisposable = MetaDisposable()
    private let fileListsDisposable = MetaDisposable()

    /// Fires on the main queue whenever `allTracks` may have changed.
    let updated = ValuePipe<Void>()

    private(set) var playlists: [MusicPlaylist]
    private var favoriteFileIds = Set<Int64>()
    /// Chat files taken out of the music. Saved tracks are removed from the profile instead.
    private var removedFileIds = Set<Int64>()
    /// Stored tracks of each playlist that are not in the loaded music yet: the chat audio arrives page by page.
    private var pendingPlaylistFileIds: [Int: [MusicStoredPlaylists.FileId]] = [:]
    private var didLoadPlaylists = false
    private var editedPlaylistIds = Set<Int>()
    private let playlistsDisposable = MetaDisposable()

    /// What the player goes through when a track is started here; Play Next and Add to Queue edit it while it plays.
    private var queue: [EngineRawMessage] = []
    private let queuePromise = Promise<[EngineRawMessage]>([])

    var allTracks: [MusicTrack] {
        return self.savedMessages.map { MusicTrack(message: $0, isSaved: true) } + self.chatTracks()
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
                self.savedMessages = messages
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
            if self.didReceiveSavedIds {
                self.savedMusicContext.reload()
            }
            self.didReceiveSavedIds = true
        }))

        self.loadMoreChatMusic()

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
                self.pendingPlaylistFileIds[Int(playlist.id)] = playlist.fileIds
                return MusicPlaylist(id: Int(playlist.id), title: playlist.title, description: playlist.description, isFavorite: playlist.isFavorite, isInProfile: playlist.isInProfile, trackIds: [], cover: cover, dateAdded: playlist.dateAdded, dateUpdated: playlist.dateUpdated)
            }
            for var playlist in createdMeanwhile {
                playlist = MusicPlaylist(id: (self.playlists.map(\.id).max() ?? -1) + 1, title: playlist.title, description: playlist.description, isFavorite: playlist.isFavorite, isInProfile: playlist.isInProfile, trackIds: playlist.trackIds, cover: playlist.cover, dateAdded: playlist.dateAdded, dateUpdated: playlist.dateUpdated)
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
            return MusicStoredPlaylists.Playlist(id: Int32(clamping: playlist.id), title: playlist.title, description: playlist.description, isFavorite: playlist.isFavorite, isInProfile: playlist.isInProfile, fileIds: playlistFileIds, cover: cover, dateAdded: playlist.dateAdded, dateUpdated: playlist.dateUpdated)
        })
        let _ = self.context.engine.itemCache.put(collectionId: ApplicationSpecificItemCacheCollectionId.music, id: MusicCacheKey.playlists.buffer, item: stored).startStandalone()
    }

    deinit {
        self.savedDisposable.dispose()
        self.savedIdsDisposable.dispose()
        self.chatLoadDisposable.dispose()
        self.chatRefreshDisposable.dispose()
        self.uploadDisposable.dispose()
        self.fileListsDisposable.dispose()
        self.playlistsDisposable.dispose()
    }

    // MARK: Playlists
    // They live as long as the library: the API has nowhere to keep them.

    func playlist(id: Int) -> MusicPlaylist? {
        return self.playlists.first(where: { $0.id == id })
    }

    @discardableResult
    func createPlaylist(title: String, description: String = "", trackIds: [EngineMessage.Id] = [], cover: TelegramMediaImageRepresentation? = nil) -> MusicPlaylist {
        let now = Int32(Date().timeIntervalSince1970)
        let playlist = MusicPlaylist(id: (self.playlists.map(\.id).max() ?? -1) + 1, title: title, description: description, isFavorite: false, trackIds: trackIds, cover: cover, dateAdded: now, dateUpdated: now)
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
        if isFavorite {
            self.favoriteFileIds.insert(fileId)
        } else {
            self.favoriteFileIds.remove(fileId)
        }
        self.storeFileIds(self.favoriteFileIds, key: .favorites)
        self.notifyUpdated()
    }

    /// Saved tracks leave the profile; chat files stay in their chats and only leave this list.
    func remove(tracks: [MusicTrack]) {
        var removedChatFile = false
        for track in tracks {
            guard let file = track.file else {
                continue
            }
            self.favoriteFileIds.remove(file.fileId.id)
            if track.isSaved {
                let _ = self.savedMusicContext.removeMusic(file: .standalone(media: file)).startStandalone()
            } else {
                self.removedFileIds.insert(file.fileId.id)
                removedChatFile = true
            }
        }
        let removedIds = Set(tracks.map(\.message.id))
        self.savedMessages.removeAll(where: { removedIds.contains($0.id) })
        self.storeFileIds(self.favoriteFileIds, key: .favorites)
        if removedChatFile {
            self.storeFileIds(self.removedFileIds, key: .removed)
        }
        self.notifyUpdated()
    }

    /// Adds a chat's track to the profile, or takes a saved one off it.
    func setSavedToProfile(_ track: MusicTrack, _ isSaved: Bool) {
        guard let file = track.file else {
            return
        }
        if isSaved {
            let _ = self.context.engine.peers.addSavedMusic(file: .message(message: MessageReference(track.message), media: file)).startStandalone()
        } else {
            let _ = self.savedMusicContext.removeMusic(file: .standalone(media: file)).startStandalone()
        }
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

    /// Uploads an audio file and saves it to the profile, as the music player's Add does.
    func addTrack(url: URL, completion: @escaping (Bool) -> Void) {
        let context = self.context
        self.uploadDisposable.set((iCloudFileDescription(url)
        |> deliverOnMainQueue).start(next: { [weak self] item in
            guard let self else {
                return
            }
            guard let item else {
                completion(false)
                return
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
            let file = TelegramMediaFile(fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: Int64.random(in: Int64.min ... Int64.max)), partialReference: nil, resource: ICloudFileResource(urlData: item.urlData, thumbnail: false), previewRepresentations: previewRepresentations, videoThumbnails: [], immediateThumbnailData: nil, mimeType: mimeType, size: Int64(item.fileSize), attributes: attributes, alternativeRepresentations: [])

            self.uploadDisposable.set((standaloneUploadedFile(
                postbox: context.account.postbox,
                network: context.account.network,
                peerId: context.account.peerId,
                text: "",
                source: .resource(.media(media: .standalone(media: file), resource: file.resource)),
                thumbnailData: file.immediateThumbnailData,
                mimeType: file.mimeType,
                attributes: file.attributes,
                hintFileIsLarge: false
            )
            |> deliverOnMainQueue).start(next: { [weak self] value in
                guard let self, case let .result(result) = value, case let .media(resultMedia) = result, let resultFile = resultMedia.media as? TelegramMediaFile else {
                    return
                }
                context.engine.resources.moveResourceData(from: EngineMediaResource.Id(file.resource.id), to: EngineMediaResource.Id(resultFile.resource.id), synchronous: true)
                self.uploadDisposable.set((context.engine.peers.addSavedMusic(file: .standalone(media: resultFile))
                |> deliverOnMainQueue).start(error: { _ in
                    completion(false)
                }, completed: {
                    completion(true)
                }))
            }, error: { _ in
                completion(false)
            }))
        }))
    }

    /// Plays in the order of the list the track was started from. The player reads the queue again at every
    /// track change, so editing it while it plays changes what comes next.
    func playlistLocation(track: MusicTrack, tracks: [MusicTrack]) -> PeerMessagesPlaylistLocation {
        self.queue = tracks.map(\.message)
        self.queuePromise.set(.single(self.queue))
        let queue = self.queuePromise.get()
        |> map { messages -> ([EngineRawMessage], Int32, Bool) in
            return (messages, Int32(messages.count), false)
        }
        return .custom(messages: queue, canReorder: false, at: track.message.id, loadMore: nil, hidePanel: false)
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
            self.queue = queue
            self.queuePromise.set(.single(queue))
            completion(true)
        })
    }

    private func chatMusicSearch(state: SearchMessagesState?) -> Signal<(SearchMessagesResult, SearchMessagesState), NoError> {
        return self.context.engine.messages.searchMessages(location: .general(scope: .everywhere, groupId: nil, tags: [.music], minDate: nil, maxDate: nil, folderId: nil, communityId: nil), query: "", state: state)
    }

    private func chatTracks() -> [MusicTrack] {
        var fileIds = Set(self.savedMessages.compactMap { musicFileId($0) })
        var tracks: [MusicTrack] = []
        for message in self.chatMessages {
            guard let fileId = musicFileId(message), !self.removedFileIds.contains(fileId.id), fileIds.insert(fileId).inserted else {
                continue
            }
            tracks.append(MusicTrack(message: message, isSaved: false))
        }
        return tracks
    }

    private func notifyUpdated() {
        self.resolvePlaylistTracks()
        self.updated.putNext(Void())
    }
}

private func musicFileId(_ message: EngineRawMessage) -> EngineMedia.Id? {
    for media in message.media {
        if let file = media as? TelegramMediaFile {
            return file.fileId
        }
    }
    return nil
}
