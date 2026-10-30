import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import ChatPresentationInterfaceState
import LegacyChatHeaderPanelComponent

/// Native header shared with pinned-message panels: reserves history space rather
/// than covering messages or the composer. The database, not a tap-time timer, is
/// the source of truth for upload, rescheduling, failure and server delivery.
final class PersonalForkSendQueuePanelNode: ChatTitleAccessoryPanelNode {
    private let context: AccountContext
    private let button = HighlightableButtonNode()
    private let titleNode = ImmediateTextNode()
    private let detailNode = ImmediateTextNode()
    private let separatorNode = ASDisplayNode()
    private let disposable = MetaDisposable()
    private var foregroundDisposable: Disposable?
    private var timer: SwiftSignalKit.Timer?
    private var peerId: EnginePeer.Id?
    private var threadId: Int64?
    private var messages: [EngineMessage] = []
    private var inFocus = false
    private var inForeground = false
    private var validLayout: (CGFloat, CGFloat, CGFloat, ChatPresentationInterfaceState)?
    var visibilityChanged: (() -> Void)?
    var openQueue: (() -> Void)?
    var hasMessages: Bool { !self.messages.isEmpty }

    init(context: AccountContext) {
        self.context = context
        super.init()
        self.titleNode.maximumNumberOfLines = 1
        self.detailNode.maximumNumberOfLines = 1
        self.titleNode.isUserInteractionEnabled = false
        self.detailNode.isUserInteractionEnabled = false
        self.separatorNode.isLayerBacked = true
        self.addSubnode(self.button)
        self.button.addSubnode(self.titleNode)
        self.button.addSubnode(self.detailNode)
        self.addSubnode(self.separatorNode)
        self.button.isAccessibilityElement = true
        self.button.accessibilityTraits = .button
        self.button.accessibilityHint = "Открывает очередь. Можно изменить или отменить отправку."
        self.button.addTarget(self, action: #selector(self.pressed), forControlEvents: .touchUpInside)
        self.foregroundDisposable = (context.sharedContext.applicationBindings.applicationInForeground
        |> deliverOnMainQueue).start(next: { [weak self] value in
            self?.inForeground = value
            self?.updateTimer()
            self?.refreshText()
        })
    }

    deinit {
        self.disposable.dispose()
        self.foregroundDisposable?.dispose()
        self.timer?.invalidate()
    }

    @objc private func pressed() {
        self.openQueue?()
    }

    func setInFocus(_ value: Bool) {
        self.inFocus = value
        self.updateTimer()
        self.refreshText()
    }

    func updateLocation(peerId: EnginePeer.Id, threadId: Int64?) {
        guard self.peerId != peerId || self.threadId != threadId else {
            return
        }
        self.peerId = peerId
        self.threadId = threadId
        self.messages = []
        self.updateTimer()
        self.disposable.set((self.context.account.viewTracker.scheduledMessagesViewForLocation(.peer(peerId: peerId, threadId: threadId))
        |> map { view, _, _ -> [EngineMessage] in
            return view.entries.map { EngineMessage($0.message) }
        }
        |> deliverOnMainQueue).start(next: { [weak self] messages in
            guard let self else { return }
            let wasVisible = self.hasMessages
            self.messages = messages
            self.updateTimer()
            self.refreshText()
            if wasVisible != self.hasMessages {
                self.visibilityChanged?()
            }
        }))
    }

    private func updateTimer() {
        // Failed-only queues do not need a ticking timer. Stop entirely in the
        // background / when another chat is visible; recompute on return.
        let needsTimer = self.inFocus && self.inForeground && self.messages.contains { !$0.flags.contains(.Failed) && !self.isPreparing($0) }
        if needsTimer && self.timer == nil {
            let timer = SwiftSignalKit.Timer(timeout: 1.0, repeat: true, completion: { [weak self] in
                self?.refreshText()
            }, queue: Queue.mainQueue())
            self.timer = timer
            timer.start()
        } else if !needsTimer {
            self.timer?.invalidate()
            self.timer = nil
        }
    }

    private func isPreparing(_ message: EngineMessage) -> Bool {
        return message.id.namespace == Namespaces.Message.ScheduledLocal || message.flags.contains(.Unsent) || message.flags.contains(.Sending)
    }

    private func refreshText() {
        guard let (width, leftInset, rightInset, interfaceState) = self.validLayout else {
            return
        }
        let _ = self.updateLayout(width: width, leftInset: leftInset, rightInset: rightInset, transition: .immediate, interfaceState: interfaceState)
    }

    override func updateLayout(width: CGFloat, leftInset: CGFloat, rightInset: CGFloat, transition: ContainedViewLayoutTransition, interfaceState: ChatPresentationInterfaceState) -> LayoutResult {
        self.validLayout = (width, leftInset, rightInset, interfaceState)
        let failed = self.messages.filter { $0.flags.contains(.Failed) }.count
        let uploading = self.messages.filter { !$0.flags.contains(.Failed) && self.isPreparing($0) }.count
        let ready = self.messages.filter { !$0.flags.contains(.Failed) && !self.isPreparing($0) }
        let nextTimestamp = ready.map { $0.timestamp }.min()
        let count = self.messages.count >= 200 ? "200+" : "\(self.messages.count)"
        let title: String
        let detail: String
        if failed > 0 {
            title = "Не отправлено: \(failed) · очередь \(count)"
            detail = "Открыть очередь · повторить или удалить ›"
        } else if let nextTimestamp {
            let remaining = max(0, Int64(nextTimestamp) - Int64(self.context.account.network.getApproximateRemoteTimestamp()))
            if nextTimestamp == scheduleWhenOnlineTimestamp {
                title = "Отправка, когда собеседник в сети"
            } else if remaining == 0 {
                title = "Отправляется… · очередь \(count)"
            } else if remaining < 3600 {
                title = "Отправка через \(remaining / 60):\(String(format: "%02d", Int(remaining % 60))) · очередь \(count)"
            } else {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                title = "Отправка \(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(nextTimestamp))))"
            }
            detail = uploading > 0 ? "Ещё загружается: \(uploading) · открыть очередь ›" : "Сообщение сохранено · изменить или отменить ›"
        } else {
            title = "Подготовка и загрузка · очередь \(count)"
            detail = "Таймер появится после загрузки · открыть очередь ›"
        }
        let theme = interfaceState.theme
        let color = failed > 0 ? theme.list.itemDestructiveColor : theme.rootController.navigationBar.accentTextColor
        self.titleNode.attributedText = NSAttributedString(string: title, font: Font.medium(14.0), textColor: color)
        self.detailNode.attributedText = NSAttributedString(string: detail, font: Font.regular(12.0), textColor: theme.rootController.navigationBar.secondaryTextColor)
        self.separatorNode.backgroundColor = theme.rootController.navigationBar.separatorColor
        let height: CGFloat = 54.0
        let availableWidth = max(0.0, width - leftInset - rightInset - 32.0)
        let titleSize = self.titleNode.updateLayout(CGSize(width: availableWidth, height: 24.0))
        let detailSize = self.detailNode.updateLayout(CGSize(width: availableWidth, height: 20.0))
        transition.updateFrame(node: self.button, frame: CGRect(x: 0.0, y: 0.0, width: width, height: height))
        transition.updateFrame(node: self.titleNode, frame: CGRect(x: leftInset + 16.0, y: 8.0, width: titleSize.width, height: titleSize.height))
        transition.updateFrame(node: self.detailNode, frame: CGRect(x: leftInset + 16.0, y: 29.0, width: detailSize.width, height: detailSize.height))
        transition.updateFrame(node: self.separatorNode, frame: CGRect(x: 0.0, y: height - UIScreenPixel, width: width, height: UIScreenPixel))
        self.button.accessibilityLabel = title + ". " + detail
        return LayoutResult(backgroundHeight: height, insetHeight: height, hitTestSlop: 0.0)
    }
}
