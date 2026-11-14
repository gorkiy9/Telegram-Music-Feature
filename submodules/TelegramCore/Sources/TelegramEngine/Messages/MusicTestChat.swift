import Foundation
import Postbox
import SwiftSignalKit

/// Music section concept: a local chat to forward tracks and playlists into while their look in chats is designed.
/// The peer exists only in this device's Postbox. Its history is never fetched, and messages sent to it are stored
/// as delivered instead of going to the pending queue, so nothing about it reaches the server.
public let musicTestChatPeerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(1_099_511_627_000))

/// Debug builds only: a release build never creates the chat, and the history and send paths stay untouched.
func isMusicTestChat(_ peerId: PeerId) -> Bool {
    #if DEBUG
    return peerId == musicTestChatPeerId
    #else
    return false
    #endif
}

public extension TelegramEngine.Messages {
    /// Puts the test chat into the chat list (and so into the share sheet). Safe to call on every launch.
    func ensureMusicTestChat(title: String) -> Signal<Never, NoError> {
        #if !DEBUG
        return .complete()
        #else
        return self.account.postbox.transaction { transaction -> Void in
            let peer = TelegramUser(id: musicTestChatPeerId, accessHash: nil, firstName: title, lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
            transaction.updatePeersInternal([peer], update: { _, updated in
                return updated
            })
            // A user chat waits for the profile's business intro before showing its history, and the server has no
            // profile for this peer: store a known empty one locally.
            transaction.updatePeerCachedData(peerIds: Set([musicTestChatPeerId]), update: { _, current in
                let cachedData = (current as? CachedUserData) ?? CachedUserData()
                if case .known = cachedData.businessIntro {
                    return cachedData
                }
                return cachedData.withUpdatedBusinessIntro(nil)
            })
            transaction.removeHole(peerId: musicTestChatPeerId, threadId: nil, namespace: Namespaces.Message.Cloud, space: .everywhere, range: 1 ... (Int32.max - 1))
            if case .notIncluded = transaction.getPeerChatListInclusion(musicTestChatPeerId) {
                transaction.updatePeerChatListInclusion(musicTestChatPeerId, inclusion: .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: Int32(Date().timeIntervalSince1970)))
            }
        }
        |> ignoreValues
        #endif
    }
}

public extension TelegramEngine.Messages {
    /// Stores audio files as one incoming group from the test chat, the way several sent tracks are grouped (concept only,
    /// nothing reaches the server). Safe to call on every launch: the group is rebuilt only when its files change.
    func addMusicTestChatIncomingFiles(_ files: [(messageId: Int32, file: TelegramMediaFile)]) -> Signal<Never, NoError> {
        #if !DEBUG
        return .complete()
        #else
        return self.account.postbox.transaction { transaction -> Void in
            if files.isEmpty {
                return
            }
            let ids = files.map { MessageId(peerId: musicTestChatPeerId, namespace: Namespaces.Message.Cloud, id: $0.messageId) }
            // A stable key per set of files, so an unchanged group is left as it is.
            var groupingKey: Int64 = 1469598103934665603
            for id in ids {
                groupingKey = (groupingKey ^ Int64(id.id)) &* 1099511628211
            }
            let existing = ids.compactMap { transaction.getMessage($0) }
            if files.count > 1 {
                if existing.count == ids.count && existing.allSatisfy({ $0.groupingKey == groupingKey }) {
                    return
                }
            } else if existing.count == ids.count {
                return
            }
            let timestamp = existing.map(\.timestamp).min() ?? Int32(Date().timeIntervalSince1970)
            transaction.deleteMessages(existing.map(\.id), forEachMedia: nil)
            var messages: [StoreMessage] = []
            for (id, (_, file)) in zip(ids, files) {
                let (tags, globalTags) = tagsForStoreMessage(incoming: true, attributes: [], media: [file], textEntities: nil, isPinned: false)
                messages.append(StoreMessage(id: id, customStableId: nil, globallyUniqueId: nil, groupingKey: files.count > 1 ? groupingKey : nil, threadId: nil, timestamp: timestamp, flags: [.Incoming], tags: tags, globalTags: globalTags, localTags: [], forwardInfo: nil, authorId: musicTestChatPeerId, text: "", attributes: [], media: [file]))
            }
            let _ = transaction.addMessages(messages, location: .UpperHistoryBlock)
        }
        |> ignoreValues
        #endif
    }
}
