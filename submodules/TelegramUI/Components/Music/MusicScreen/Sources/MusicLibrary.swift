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
    }

    var key: Key
    var ascending: Bool

    /// Tapping the selected key reverses it, any other key starts from its natural order.
    func selecting(_ key: Key) -> MusicSorting {
        if key == self.key {
            return MusicSorting(key: key, ascending: !self.ascending)
        }
        switch key {
        case .title, .artist:
            return MusicSorting(key: key, ascending: true)
        case .dateAdded, .lastPlayed, .dateUpdated:
            return MusicSorting(key: key, ascending: false)
        }
    }
}

/// The API has no playlists: Playlists shows this local stand-in until it does.
struct MusicPlaylist {
    let id: Int
    let title: String
    var trackIds: [EngineMessage.Id] = []
}

/// Which tracks a list shows.
enum MusicTrackSource: Equatable {
    case all
    case artist(String)
    case favorites
}

/// Files picked out on this device: the API has neither favorites nor a way to take a chat's file out of the music.
private struct MusicFileIdList: Codable {
    let fileIds: [Int64]
}

private struct MusicTabSettings: Codable {
    let isShown: Bool
}

/// The section's local state shares one item cache collection, one entry per kind.
private enum MusicCacheKey: Int32 {
    // 0 held play counts, which nothing reads any more.
    case favorites = 1
    case removed = 2
    case tabSettings = 3

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
        self.playlists = [MusicPlaylist(id: 0, title: playlistTitle)]

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
    }

    deinit {
        self.savedDisposable.dispose()
        self.savedIdsDisposable.dispose()
        self.chatLoadDisposable.dispose()
        self.chatRefreshDisposable.dispose()
        self.uploadDisposable.dispose()
        self.fileListsDisposable.dispose()
    }

    /// Lives as long as the library: the API has nowhere to keep it.
    @discardableResult
    func createPlaylist(title: String) -> MusicPlaylist {
        let playlist = MusicPlaylist(id: self.playlists.count, title: title)
        self.playlists.append(playlist)
        self.notifyUpdated()
        return playlist
    }

    /// Kept in memory with the stand-in playlists; no screen shows a playlist's tracks yet.
    func add(track: MusicTrack, to playlist: MusicPlaylist) {
        guard let index = self.playlists.firstIndex(where: { $0.id == playlist.id }) else {
            return
        }
        var trackIds = self.playlists[index].trackIds
        if !trackIds.contains(track.message.id) {
            trackIds.append(track.message.id)
        }
        self.playlists[index] = MusicPlaylist(id: playlist.id, title: playlist.title, trackIds: trackIds)
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
        case .dateAdded, .lastPlayed, .dateUpdated:
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

    /// Puts the track right after the playing one, or at the end of the queue.
    /// Completes with false when nothing from this section is playing: there is no queue to edit.
    func enqueue(track: MusicTrack, next: Bool, completion: @escaping (Bool) -> Void) {
        let _ = (self.context.sharedContext.mediaManager.musicMediaPlayerState
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let self, let state, case let .state(itemState) = state.1, let itemId = itemState.item.id as? PeerMessagesMediaPlaylistItemId, let currentIndex = self.queue.firstIndex(where: { $0.id == itemId.messageId }) else {
                completion(false)
                return
            }
            var queue = self.queue
            let currentId = queue[currentIndex].id
            if track.message.id != currentId {
                queue.removeAll(where: { $0.id == track.message.id })
                if next, let index = queue.firstIndex(where: { $0.id == currentId }) {
                    queue.insert(track.message, at: index + 1)
                } else {
                    queue.append(track.message)
                }
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
