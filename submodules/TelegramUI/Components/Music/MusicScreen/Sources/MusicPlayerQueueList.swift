import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import MergeLists
import ListMessageItem
import ContextUI

private struct MusicPlayerQueueEntry: Comparable, Identifiable {
    let index: Int
    let message: EngineRawMessage
    let isFavorite: Bool
    let canReorder: Bool
    let playingIndicator: ListMessageItemPlayingIndicator?

    var stableId: EngineMessage.Id {
        return self.message.id
    }

    static func ==(lhs: MusicPlayerQueueEntry, rhs: MusicPlayerQueueEntry) -> Bool {
        // Identity too: an edited track is a new message with the same id and version.
        // The index too, as the client's item lists do: a row a move passes is then updated with its node, and the
        // list carries that node to the row's new place instead of drawing it a row too high for a frame.
        return lhs.index == rhs.index && lhs.message.id == rhs.message.id && lhs.message === rhs.message && lhs.isFavorite == rhs.isFavorite && lhs.canReorder == rhs.canReorder && lhs.playingIndicator == rhs.playingIndicator
    }

    static func <(lhs: MusicPlayerQueueEntry, rhs: MusicPlayerQueueEntry) -> Bool {
        return lhs.index < rhs.index
    }
}

/// The player sheet's queue (Figma Player / Queue List 301:17254) as the Music section's track rows: the whole queue
/// in play order, the playing track with the sound wave on its cover and kept at the top of the visible list, the
/// tracks played before it above (scroll up to see them), the ones to come below; every row has the client's grabber.
public final class MusicPlayerQueueListNode: ASDisplayNode {
    private let context: AccountContext
    private var presentationData: PresentationData
    private let listNode = ListViewImpl()
    private var entries: [MusicPlayerQueueEntry] = []
    private var currentId: EngineMessage.Id?
    private var isPaused = false
    private var canReorder = false
    private var validLayout: (size: CGSize, insets: UIEdgeInsets)?
    private static let rowHeight: CGFloat = 62.0
    private var isReordering = false

    /// A row was tapped: the track plays in the same queue.
    public var openMessage: ((EngineRawMessage) -> Void)?
    public var openContextMenu: ((EngineRawMessage, ASDisplayNode, ContextGesture?) -> Void)?
    /// A track still to come was dragged to another place; the index is in the whole list.
    public var moveMessage: ((EngineMessage.Id, Int) -> Void)?

    public init(context: AccountContext, presentationData: PresentationData) {
        self.context = context
        self.presentationData = presentationData

        super.init()

        self.listNode.verticalScrollIndicatorColor = presentationData.theme.list.scrollIndicatorColor
        self.addSubnode(self.listNode)

        // A drag steps one place at a time as soon as the row crosses its neighbour (the client waits 0.2 s between
        // steps, so a quick drag jumped several rows at once), and the list scrolls only from the first or the last row
        // on screen, slowly at first and faster the further the row goes in, instead of at a fixed speed at once.
        self.listNode.reorderingStepInterval = 0.06
        // The dragged row covers the one it replaces before that one gives way (the client swaps at its near edge).
        self.listNode.reorderingSwapsAtItemCenter = true
        self.listNode.reorderingAutoScrollSpeed = { depth in
            let progress = max(0.0, min(1.0, depth / MusicPlayerQueueListNode.rowHeight))
            return 1.0 + 13.0 * progress * progress
        }
        // While a row is dragged, the list scrolls only once it reaches the first or the last row on screen: the
        // client starts scrolling within 10 pt of the visible edges, measured from the dragged row's centre.
        self.listNode.reorderBegan = { [weak self] in
            self?.isReordering = true
            self?.updateVisualInsets()
        }
        self.listNode.reorderCompleted = { [weak self] _ in
            self?.isReordering = false
            self?.updateVisualInsets()
        }
        self.listNode.reorderItem = { [weak self] fromIndex, toIndex, _ in
            guard let self, fromIndex != toIndex, self.entries.indices.contains(fromIndex) else {
                return .single(false)
            }
            // Any track moves, the playing one and those that played too: the queue plays on from wherever the
            // playing track now stands.
            // As the chat list does with pinned chats: the drag changes the data only, the list keeps the dragged row
            // under the finger and the order arrives through its usual update, which slides the rows into place.
            let message = self.entries[fromIndex].message
            self.moveMessage?(message.id, toIndex)
            return .single(true)
        }
    }

    private var favoriteFileIds: Set<Int64> {
        return Set(self.entries.filter(\.isFavorite).compactMap { musicQueueFileId($0.message) })
    }

    public func updatePresentationData(_ presentationData: PresentationData) {
        self.presentationData = presentationData
        self.listNode.verticalScrollIndicatorColor = presentationData.theme.list.scrollIndicatorColor
        self.apply(messages: self.entries.map(\.message), favoriteFileIds: self.favoriteFileIds, allUpdated: true, animated: false, scrollToCurrent: false)
    }

    /// `messages` is the queue in play order. When the playing track changes, the list moves on by it: the new track
    /// comes to the top of what is visible.
    public func update(messages: [EngineRawMessage], favoriteFileIds: Set<Int64>, currentId: EngineMessage.Id?, isPaused: Bool, canReorder: Bool, animated: Bool) {
        let currentChanged = self.currentId != currentId
        let isFirst = self.entries.isEmpty
        self.currentId = currentId
        self.isPaused = isPaused
        self.canReorder = canReorder
        self.apply(messages: messages, favoriteFileIds: favoriteFileIds, animated: animated && !isFirst, scrollToCurrent: currentChanged || isFirst, scrollAnimated: animated && !isFirst)
    }

    private func apply(messages: [EngineRawMessage], favoriteFileIds: Set<Int64>, allUpdated: Bool = false, animated: Bool, scrollToCurrent: Bool, scrollAnimated: Bool = false) {
        var seen = Set<EngineMessage.Id>()
        var entries: [MusicPlayerQueueEntry] = []
        var currentIndex: Int?
        for message in messages where !seen.contains(message.id) {
            seen.insert(message.id)
            let isFavorite = musicQueueFileId(message).flatMap { favoriteFileIds.contains($0) } ?? false
            var indicator: ListMessageItemPlayingIndicator?
            if message.id == self.currentId {
                currentIndex = entries.count
                indicator = self.isPaused ? .paused : .playing
            }
            entries.append(MusicPlayerQueueEntry(index: entries.count, message: message, isFavorite: isFavorite, canReorder: self.canReorder, playingIndicator: indicator))
        }
        let (deleteIndices, indicesAndItems, updateIndices) = mergeListsStableWithUpdates(leftList: self.entries, rightList: entries, allUpdated: allUpdated)
        self.entries = entries
        var scrollToItem: ListViewScrollToItem?
        if scrollToCurrent, let currentIndex, self.validLayout != nil {
            scrollToItem = ListViewScrollToItem(index: currentIndex, position: .top(0.0), animated: scrollAnimated, curve: .Spring(duration: 0.4), directionHint: .Down)
        }
        self.listNode.transaction(
            deleteIndices: deleteIndices.map { ListViewDeleteItem(index: $0, directionHint: nil) },
            insertIndicesAndItems: indicesAndItems.map { ListViewInsertItem(index: $0.0, previousIndex: $0.2, item: self.item(entry: $0.1), directionHint: nil) },
            updateIndicesAndItems: updateIndices.map { ListViewUpdateItem(index: $0.0, previousIndex: $0.2, item: self.item(entry: $0.1), directionHint: nil) },
            options: animated ? [.Synchronous, .LowLatency, .AnimateInsertion] : [.Synchronous, .LowLatency],
            scrollToItem: scrollToItem,
            updateOpaqueState: nil
        )
    }

    public func updateLayout(size: CGSize, insets: UIEdgeInsets, transition: ContainedViewLayoutTransition) {
        // The sheet lays out again on every player and library update; an unchanged size must not run a list
        // transaction in the middle of a drag or a scroll.
        if let (currentSize, currentInsets) = self.validLayout, currentSize == size, currentInsets == insets {
            return
        }
        let isFirstLayout = self.validLayout == nil
        self.validLayout = (size, insets)
        transition.updateFrame(node: self.listNode, frame: CGRect(origin: CGPoint(), size: size))
        var listInsets = insets
        // Room below the last track, so the playing one can reach the top even at the end of the queue.
        listInsets.bottom = max(insets.bottom, size.height - MusicPlayerQueueListNode.rowHeight)
        let (duration, curve) = listViewAnimationDurationAndCurve(transition: transition)
        var scrollToItem: ListViewScrollToItem?
        if isFirstLayout, let currentIndex = self.entries.firstIndex(where: { $0.message.id == self.currentId }) {
            scrollToItem = ListViewScrollToItem(index: currentIndex, position: .top(0.0), animated: false, curve: .Default(duration: nil), directionHint: .Down)
        }
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: scrollToItem, updateSizeAndInsets: ListViewUpdateSizeAndInsets(size: size, insets: listInsets, duration: duration, curve: curve), updateOpaqueState: nil)
        self.updateVisualInsets()
    }

    /// What is actually on screen: the list's own bottom inset is room to bring the last track to the top, not a
    /// visible area. While dragging, the edges move in by a row less the client's 10 pt, so scrolling starts when the
    /// dragged row reaches the first or the last visible row.
    private func updateVisualInsets() {
        guard let (_, insets) = self.validLayout else {
            return
        }
        var visualInsets = UIEdgeInsets(top: insets.top, left: 0.0, bottom: insets.bottom, right: 0.0)
        if self.isReordering {
            let edge = MusicPlayerQueueListNode.rowHeight - 10.0
            visualInsets.top += edge
            visualInsets.bottom += edge
        }
        self.listNode.visualInsets = visualInsets
    }

    private func item(entry: MusicPlayerQueueEntry) -> ListViewItem {
        let presentationData = self.presentationData
        let interaction = ListMessageItemInteraction(openMessage: { [weak self] message, _ in
            self?.openMessage?(message)
            return true
        }, openMessageContextMenu: { [weak self] message, _, node, _, gesture in
            self?.openContextMenu?(message, node, gesture as? ContextGesture)
        }, toggleMediaPlayback: { [weak self] message in
            self?.openMessage?(message)
        }, toggleMessagesSelection: { _, _ in
        }, openUrl: { _, _, _, _ in
        }, openInstantPage: { _, _ in
        }, longTap: { _, _ in
        }, getHiddenMedia: {
            return [:]
        })
        let message = entry.message
        let isSaved = message.id.namespace != Namespaces.Message.Cloud
        return ListMessageItem(presentationData: musicChatPresentationData(presentationData), systemStyle: .glass, context: self.context, chatLocation: .peer(id: message.id.peerId), interaction: interaction, message: message, selection: .none, displayHeader: false, isGlobalSearchResult: !isSaved, isSavedMusic: isSaved, displayFileInfo: true, audioInfo: .performer, hidesAudioFileExtension: true, blockTopInset: 0.0, displayBackground: false, canReorder: entry.canReorder, reorderBackgroundColor: presentationData.theme.chatList.pinnedItemBackgroundColor, trailingIcon: entry.isFavorite ? MusicResources.favoriteMark(theme: presentationData.theme) : nil, displaysAudioCover: true, playingIndicator: entry.playingIndicator, style: .plain, sectionId: 0)
    }
}

private func musicQueueFileId(_ message: EngineRawMessage) -> Int64? {
    for media in message.media {
        if let file = media as? TelegramMediaFile {
            return file.fileId.id
        }
    }
    return nil
}
