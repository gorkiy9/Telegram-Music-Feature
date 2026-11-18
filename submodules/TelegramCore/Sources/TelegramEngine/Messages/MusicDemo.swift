import Foundation
import Postbox
import SwiftSignalKit

/// Music section concept: the build used to record the demo video. It is a separate app (its bundle id contains
/// "MusicDemo", so it has its own data container and never sees the regular app's account), it signs in to the test
/// servers only, and its chats, users and music are local stand-ins that never reach any server.
public let isMusicDemoBuild: Bool = {
    guard let bundleId = Bundle.main.bundleIdentifier else {
        return false
    }
    return bundleId.contains("MusicDemo")
}()

private let musicDemoPeerIdBase: Int64 = 1_099_511_627_100
private let musicDemoPeerIdCount: Int64 = 100

/// The demo's local users and groups: ids next to the test chat's, never assigned by the server.
public func musicDemoPeerId(index: Int, isGroup: Bool) -> EnginePeer.Id {
    return PeerId(namespace: isGroup ? Namespaces.Peer.CloudGroup : Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(musicDemoPeerIdBase + Int64(index)))
}

/// A demo peer: its history is local, and messages sent to it are stored as delivered.
public func isMusicDemoPeer(_ peerId: EnginePeer.Id) -> Bool {
    guard isMusicDemoBuild else {
        return false
    }
    guard peerId.namespace == Namespaces.Peer.CloudUser || peerId.namespace == Namespaces.Peer.CloudGroup else {
        return false
    }
    let value = peerId.id._internalGetInt64Value()
    return value >= musicDemoPeerIdBase && value < musicDemoPeerIdBase + musicDemoPeerIdCount
}

/// What the demo puts in the account: its chats, their messages and the profiles' music.
public struct MusicDemoSeed {
    public enum PeerKind {
        case user(firstName: String, lastName: String?, isInChatList: Bool)
        /// A bot's chat: in the chat list, drawn as a bot (no last seen, bot profile).
        case bot(name: String)
        case group(title: String, memberCount: Int)
    }

    public struct Peer {
        public let id: EnginePeer.Id
        public let kind: PeerKind
        /// Unread incoming messages the chat list shows.
        public let unreadCount: Int32

        public init(id: EnginePeer.Id, kind: PeerKind, unreadCount: Int32 = 0) {
            self.id = id
            self.kind = kind
            self.unreadCount = unreadCount
        }
    }

    public struct Message {
        public let peerId: EnginePeer.Id
        public let id: Int32
        /// Nil: sent by the account.
        public let authorId: EnginePeer.Id?
        public let timestamp: Int32
        public let text: String
        public let file: TelegramMediaFile?
        public let webpage: TelegramMediaWebpage?
        public let groupingKey: Int64?

        public init(peerId: EnginePeer.Id, id: Int32, authorId: EnginePeer.Id?, timestamp: Int32, text: String, file: TelegramMediaFile? = nil, webpage: TelegramMediaWebpage? = nil, groupingKey: Int64? = nil) {
            self.peerId = peerId
            self.id = id
            self.authorId = authorId
            self.timestamp = timestamp
            self.text = text
            self.file = file
            self.webpage = webpage
            self.groupingKey = groupingKey
        }
    }

    public let peers: [Peer]
    public let messages: [Message]
    /// The tracks each user's profile shows; the account's own profile starts with `accountSavedMusic`.
    public let savedMusic: [EnginePeer.Id: [TelegramMediaFile]]
    public let accountSavedMusic: [TelegramMediaFile]

    public init(peers: [Peer], messages: [Message], savedMusic: [EnginePeer.Id: [TelegramMediaFile]], accountSavedMusic: [TelegramMediaFile]) {
        self.peers = peers
        self.messages = messages
        self.savedMusic = savedMusic
        self.accountSavedMusic = accountSavedMusic
    }
}

public extension TelegramEngine.Messages {
    /// Writes the demo's chats from scratch: earlier demo messages (also those sent while recording) are dropped, so every
    /// take starts from the same state. Chats that are not the demo's leave the chat list.
    func seedMusicDemo(_ seed: MusicDemoSeed) -> Signal<Never, NoError> {
        guard isMusicDemoBuild else {
            return .complete()
        }
        let accountPeerId = self.account.peerId
        return self.account.postbox.transaction { transaction -> Void in
            var peers: [Peer] = []
            for peer in seed.peers {
                switch peer.kind {
                case let .user(firstName, lastName, _):
                    peers.append(TelegramUser(id: peer.id, accessHash: nil, firstName: firstName, lastName: lastName, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil))
                case let .bot(name):
                    peers.append(TelegramUser(id: peer.id, accessHash: nil, firstName: name, lastName: nil, username: nil, phone: nil, photo: [], botInfo: BotUserInfo(flags: [], inlinePlaceholder: nil), restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil))
                case let .group(title, memberCount):
                    peers.append(TelegramGroup(id: peer.id, title: title, photo: [], participantCount: memberCount, role: .member, membership: .Member, flags: [], defaultBannedRights: nil, migrationReference: nil, creationDate: 0, version: 0))
                }
            }
            transaction.updatePeersInternal(peers, update: { _, updated in
                return updated
            })

            // The demo is offline: the chat lists have nothing to load from a server.
            for groupId in [PeerGroupId.root, Namespaces.PeerGroup.archive] {
                for hole in transaction.allChatListHoles(groupId: groupId) {
                    transaction.replaceChatListHole(groupId: groupId, index: hole.index, hole: nil)
                }
            }

            // Everything already in the chat list that is not the demo's leaves it.
            let demoPeerIds = Set(seed.peers.map(\.id))
            for peerId in transaction.getChatListPeers(groupId: .root, filterPredicate: nil, additionalFilter: nil).map(\.id) where !demoPeerIds.contains(peerId) {
                transaction.updatePeerChatListInclusion(peerId, inclusion: .notIncluded)
            }

            for peer in seed.peers {
                transaction.clearHistory(peer.id, threadId: nil, minTimestamp: nil, maxTimestamp: nil, namespaces: .all, forEachMedia: nil)
                transaction.removeHole(peerId: peer.id, threadId: nil, namespace: Namespaces.Message.Cloud, space: .everywhere, range: 1 ... (Int32.max - 1))
                if peer.id.namespace == Namespaces.Peer.CloudUser {
                    // A user chat waits for the profile's business intro; the server has no profile for these peers.
                    transaction.updatePeerCachedData(peerIds: Set([peer.id]), update: { _, current in
                        let cachedData = (current as? CachedUserData) ?? CachedUserData()
                        return cachedData.withUpdatedBusinessIntro(nil).withUpdatedSavedMusic(seed.savedMusic[peer.id]?.first)
                    })
                }
            }

            var storeMessages: [StoreMessage] = []
            for message in seed.messages {
                var media: [Media] = []
                if let file = message.file {
                    media.append(file)
                }
                if let webpage = message.webpage {
                    media.append(webpage)
                }
                let isIncoming = message.authorId != nil
                let (tags, globalTags) = tagsForStoreMessage(incoming: isIncoming, attributes: [], media: media, textEntities: nil, isPinned: false)
                storeMessages.append(StoreMessage(id: MessageId(peerId: message.peerId, namespace: Namespaces.Message.Cloud, id: message.id), customStableId: nil, globallyUniqueId: nil, groupingKey: message.groupingKey, threadId: nil, timestamp: message.timestamp, flags: isIncoming ? [.Incoming] : [], tags: tags, globalTags: globalTags, localTags: [], forwardInfo: nil, authorId: message.authorId ?? accountPeerId, text: message.text, attributes: [], media: media))
            }
            let _ = transaction.addMessages(storeMessages, location: .UpperHistoryBlock)

            var readStates: [PeerId: [MessageId.Namespace: PeerReadState]] = [:]
            for peer in seed.peers {
                let maxId = seed.messages.filter { $0.peerId == peer.id }.map(\.id).max() ?? 0
                readStates[peer.id] = [Namespaces.Message.Cloud: .idBased(maxIncomingReadId: max(0, maxId - peer.unreadCount), maxOutgoingReadId: maxId, maxKnownId: maxId, count: peer.unreadCount, markedUnread: false)]
                switch peer.kind {
                case let .user(_, _, isInChatList):
                    transaction.updatePeerChatListInclusion(peer.id, inclusion: isInChatList ? .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: nil) : .notIncluded)
                case .bot, .group:
                    transaction.updatePeerChatListInclusion(peer.id, inclusion: .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: nil))
                }
            }
            transaction.resetIncomingReadStates(readStates)

            var savedMusic = seed.savedMusic
            savedMusic[accountPeerId] = seed.accountSavedMusic
            _internal_seedMusicDemoSavedMusic(transaction: transaction, accountPeerId: accountPeerId, savedMusic: savedMusic)
        }
        |> ignoreValues
    }

    /// The music files of the demo's chats, newest first: the demo's stand-in for searching every chat for music.
    func musicDemoChatMusic() -> Signal<[EngineRawMessage], NoError> {
        guard isMusicDemoBuild else {
            return .single([])
        }
        return self.account.postbox.transaction { transaction -> [EngineRawMessage] in
            var messages: [Message] = []
            for index in 0 ..< Int(musicDemoPeerIdCount) {
                for isGroup in [false, true] {
                    let peerId = musicDemoPeerId(index: index, isGroup: isGroup)
                    guard transaction.getPeer(peerId) != nil else {
                        continue
                    }
                    transaction.scanMessages(peerId: peerId, namespace: Namespaces.Message.Cloud, tag: .music, { message in
                        messages.append(message)
                        return true
                    })
                }
            }
            return messages.sorted(by: { $0.index > $1.index })
        }
    }
}

/// The demo build's own account: local only, never signed in anywhere.
public let musicDemoAccountPeerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(1_099_511_627_050))

/// Signs the demo build in without a server: the account is Alex Morgan, stored on this device only. The demo's
/// network points at a closed local port (`initializedNetwork`), so nothing can sign it out again.
public func musicDemoSignInOffline(accountManager: AccountManager<TelegramAccountManagerTypes>, account: UnauthorizedAccount) -> Signal<Never, NoError> {
    guard isMusicDemoBuild else {
        return .complete()
    }
    return account.postbox.transaction { transaction -> Void in
        let user = TelegramUser(id: musicDemoAccountPeerId, accessHash: nil, firstName: "Alex", lastName: "Morgan", username: "alexmorgan", phone: "15550100000", photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        transaction.updatePeersInternal([user], update: { _, updated in
            return updated
        })
        initializedAppSettingsAfterLogin(transaction: transaction, appVersion: account.networkArguments.appVersion, syncContacts: false)
        transaction.setState(AuthorizedAccountState(isTestingEnvironment: true, masterDatacenterId: 2, peerId: musicDemoAccountPeerId, state: nil, invalidatedChannels: []))
    }
    |> mapToSignal { _ -> Signal<Void, NoError> in
        return accountManager.transaction { transaction -> Void in
            switchToAuthorizedAccount(transaction: transaction, account: account, isSupportUser: false)
        }
    }
    |> ignoreValues
}
