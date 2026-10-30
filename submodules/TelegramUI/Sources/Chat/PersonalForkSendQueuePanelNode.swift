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
    private let disclosureNode = ImmediateTextNode()
    private let separatorNode = ASDisplayNode()
    private let disposable = MetaDisposable()
    private var foregroundDisposable: Disposable?
    private var networkDisposable: Disposable?
    private var timer: SwiftSignalKit.Timer?
    private var peerId: EnginePeer.Id?
    private var threadId: Int64?
    private var messages: [EngineMessage] = []
    private var inFocus = false
    private var inForeground = false
    private var isConnected = false
    private var validLayout: (CGFloat, CGFloat, CGFloat, ChatPresentationInterfaceState)?
    var visibilityChanged: (() -> Void)?
    var openQueue: (() -> Void)?
    var hasMessages: Bool { !self.messages.isEmpty }

    init(context: AccountContext) {
        self.context = context
        super.init()
        self.titleNode.maximumNumberOfLines = 1
        self.detailNode.maximumNumberOfLines = 1
        self.disclosureNode.isUserInteractionEnabled = false
        self.titleNode.isUserInteractionEnabled = false
        self.detailNode.isUserInteractionEnabled = false
        self.separatorNode.isLayerBacked = true
        self.addSubnode(self.button)
        self.button.addSubnode(self.titleNode)
        self.button.addSubnode(self.detailNode)
        self.button.addSubnode(self.disclosureNode)
        self.addSubnode(self.separatorNode)
        self.button.isAccessibilityElement = true
        self.button.accessibilityTraits = .button
        self.button.accessibilityHint = "Изменить или отменить отправку"
        self.button.addTarget(self, action: #selector(self.pressed), forControlEvents: .touchUpInside)
        self.foregroundDisposable = (context.sharedContext.applicationBindings.applicationInForeground
        |> deliverOnMainQueue).start(next: { [weak self] value in
            self?.inForeground = value
            self?.updateTimer()
            self?.refreshText()
        })
        self.networkDisposable = (context.account.networkState
        |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let self else { return }
            switch state {
            case .online, .updating:
                self.isConnected = true
            case .waitingForNetwork, .connecting:
                self.isConnected = false
            }
            self.refreshText()
        })
    }

    deinit {
        self.disposable.dispose()
        self.foregroundDisposable?.dispose()
        self.networkDisposable?.dispose()
        self.timer?.invalidate()
    }

    @objc private func pressed() {
        self.openQueue?()
    }

    func setInFocus(_ value: Bool) {
        guard self.inFocus != value else { return }
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
        self.refreshText()
        self.updateTimer()
        self.disposable.set((self.context.account.viewTracker.scheduledMessagesViewForLocation(.peer(peerId: peerId, threadId: threadId))
        |> map { view, _, _ -> [EngineMessage] in
            return view.entries.map { EngineMessage($0.message) }
        }
        |> deliverOnMainQueue).start(next: { [weak self] messages in
            guard let self, self.peerId == peerId, self.threadId == threadId else { return }
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
        let needsTimer = self.inFocus && self.inForeground && !self.messages.contains { $0.flags.contains(.Failed) } && self.messages.contains { !$0.flags.contains(.Failed) && !self.isPreparing($0) && $0.timestamp != scheduleWhenOnlineTimestamp }
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

    private func preview(_ message: EngineMessage?) -> String {
        guard let message else { return "Очередь отправки" }
        let text = message.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if !text.isEmpty {
            return String(text.prefix(160))
        }
        for media in message._asMessage().media {
            if media is TelegramMediaImage { return "Фото" }
            if let file = media as? TelegramMediaFile {
                if file.isInstantVideo { return "Видеосообщение" }
                if file.isVoice { return "Голосовое сообщение" }
                if file.isSticker { return "Стикер" }
                if file.isAnimated { return "GIF" }
                if file.isVideo { return "Видео" }
                return file.fileName ?? "Файл"
            }
        }
        return "Сообщение"
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
        let nextMessage = ready.min(by: { $0.timestamp < $1.timestamp })
        let nextTimestamp = nextMessage?.timestamp
        let count = self.messages.count >= 200 ? "200+" : "\(self.messages.count)"
        let countSuffix = self.messages.count > 1 ? " · \(count)" : ""
        let title: String
        let detail: String
        if failed > 0 {
            title = "Не отправлено: \(failed)"
            detail = self.preview(self.messages.first(where: { $0.flags.contains(.Failed) }))
        } else if let nextTimestamp {
            let remaining = max(0, Int64(nextTimestamp) - Int64(self.context.account.network.getApproximateRemoteTimestamp()))
            if nextTimestamp == scheduleWhenOnlineTimestamp {
                title = "Когда собеседник в сети" + countSuffix
            } else if remaining == 0 {
                title = (self.isConnected ? "Отправляется…" : "Проверка отправки…") + countSuffix
            } else if remaining < 3600 {
                title = "Отправка через \(remaining / 60):\(String(format: "%02d", Int(remaining % 60)))" + countSuffix
            } else {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                title = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(nextTimestamp))) + countSuffix
            }
            detail = uploading > 0 ? "Загрузка: \(uploading) · " + self.preview(nextMessage) : self.preview(nextMessage)
        } else {
            title = (self.isConnected ? "Подготовка к отправке…" : "Ожидание сети…") + countSuffix
            detail = self.preview(self.messages.first)
        }
        let theme = interfaceState.theme
        let color = failed > 0 ? theme.list.itemDestructiveColor : theme.rootController.navigationBar.accentTextColor
        self.titleNode.attributedText = NSAttributedString(string: title, font: Font.medium(14.0), textColor: color)
        self.detailNode.attributedText = NSAttributedString(string: detail, font: Font.regular(12.0), textColor: theme.rootController.navigationBar.secondaryTextColor)
        self.disclosureNode.attributedText = NSAttributedString(string: "›", font: Font.regular(26.0), textColor: theme.rootController.navigationBar.secondaryTextColor)
        self.separatorNode.backgroundColor = theme.rootController.navigationBar.separatorColor
        let height: CGFloat = 54.0
        let availableWidth = max(0.0, width - leftInset - rightInset - 54.0)
        let titleSize = self.titleNode.updateLayout(CGSize(width: availableWidth, height: 24.0))
        let detailSize = self.detailNode.updateLayout(CGSize(width: availableWidth, height: 20.0))
        let disclosureSize = self.disclosureNode.updateLayout(CGSize(width: 20.0, height: height))
        transition.updateFrame(node: self.button, frame: CGRect(x: 0.0, y: 0.0, width: width, height: height))
        transition.updateFrame(node: self.titleNode, frame: CGRect(x: leftInset + 16.0, y: 8.0, width: titleSize.width, height: titleSize.height))
        transition.updateFrame(node: self.detailNode, frame: CGRect(x: leftInset + 16.0, y: 29.0, width: detailSize.width, height: detailSize.height))
        transition.updateFrame(node: self.disclosureNode, frame: CGRect(x: width - rightInset - 18.0 - disclosureSize.width, y: floor((height - disclosureSize.height) * 0.5), width: disclosureSize.width, height: disclosureSize.height))
        transition.updateFrame(node: self.separatorNode, frame: CGRect(x: 0.0, y: height - UIScreenPixel, width: width, height: UIScreenPixel))
        self.button.accessibilityLabel = title + ". В очереди: " + count + ". " + detail
        return LayoutResult(backgroundHeight: height, insetHeight: height, hitTestSlop: 0.0)
    }
}
