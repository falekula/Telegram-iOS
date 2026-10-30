import Foundation
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import AccountContext
import AlertUI
import PresentationDataUtils

private final class LocalHistoryArguments {
    let loadMore: () -> Void
    init(loadMore: @escaping () -> Void) { self.loadMore = loadMore }
}

private struct LocalHistoryListEntry: ItemListNodeEntry {
    let stableId: Int32
    let text: String
    var loadMore: Bool = false

    var section: ItemListSectionId { return self.stableId }

    static func < (lhs: LocalHistoryListEntry, rhs: LocalHistoryListEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        if self.loadMore {
            let arguments = arguments as! LocalHistoryArguments
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: self.text, label: "", sectionId: self.section, style: .blocks, disclosureStyle: .arrow, action: arguments.loadMore)
        }
        return ItemListTextItem(presentationData: presentationData, text: .plain(self.text), sectionId: self.section)
    }
}

public func localMessageHistoryController(context: AccountContext, message: EngineMessage? = nil) -> ViewController {
    let visibleCount = ValuePromise(200, ignoreRepeated: true)
    var currentVisibleCount = 200
    let arguments = LocalHistoryArguments(loadMore: {
        currentVisibleCount += 200
        visibleCount.set(currentVisibleCount)
    })
    let records = Promise<[LocalMessageHistoryEntry]>()
    records.set(context.engine.messages.localMessageHistory() |> map { records in
        guard let message else { return records }
        return records.filter { $0.peerId == message.id.peerId.toInt64() && $0.messageId == message.id.id }
    })
    let currentMessage: Signal<EngineMessage?, NoError>
    if let message {
        currentMessage = context.engine.data.subscribe(TelegramEngine.EngineData.Item.Messages.Message(id: message.id))
    } else {
        currentMessage = .single(nil)
    }
    let actions = DisposableSet()
    var presentImpl: ((ViewController) -> Void)?

    let state = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, records.get(), currentMessage, context.engine.messages.localMessageHistoryLimits(), visibleCount.get())
    |> map { presentationData, records, message, limits, visibleCount -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let clear = ItemListNavigationButton(content: .text("Очистить"), style: .regular, enabled: true, action: {
            presentImpl?(textAlertController(context: context, title: "Очистить историю?", text: "Журнал, копии удалённых сообщений и исчезающих вложений удалятся навсегда. Обычные сообщения останутся.", actions: [
                TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
                TextAlertAction(type: .defaultDestructiveAction, title: "Очистить", action: {
                    actions.add((context.engine.messages.clearLocalMessageHistory()
                    |> deliverOnMainQueue).start())
                })
            ]))
        })
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Личная история"), leftNavigationButton: nil, rightNavigationButton: clear, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let usedBytes = records.reduce(0) { $0 + $1.storageByteCount }
        let usedMegabytes = String(format: "%.2f", Double(usedBytes) / (1024.0 * 1024.0))
        var info = "\(records.count) / \(limits.recordCount) записей · \(usedMegabytes) / \(limits.megabytes) МБ\nТолько личные чаты. Лимиты — в настройках xxxgram."
        if records.count > visibleCount {
            info += "\nПоказаны последние \(visibleCount). Остальные — ниже."
        }
        var entries = [LocalHistoryListEntry(stableId: 0, text: info)]
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        if records.isEmpty {
            entries.append(LocalHistoryListEntry(stableId: 1, text: "Пока нет сохранённых правок и удалений."))
        }
        for (index, record) in records.prefix(visibleCount).enumerated() {
            var text = "\(record.deleted ? "Удалено" : "Изменено") · \(formatter.string(from: Date(timeIntervalSince1970: record.observedAt)))\n\(record.chatTitle)"
            if !record.author.isEmpty {
                text += " · \(record.author)"
            }
            text += "\nСообщение №\(record.messageId) · \(formatter.string(from: Date(timeIntervalSince1970: Double(record.timestamp))))\n\n\(record.text.isEmpty ? "[Без текста]" : record.text)"
            if let updatedText = record.updatedText {
                text += "\n\nПосле правки:\n\(updatedText.isEmpty ? "[Без текста]" : updatedText)"
            }
            if record.hadMedia {
                text += "\n\n[Вложение: откройте сохранённое сообщение в чате]"
            }
            entries.append(LocalHistoryListEntry(stableId: Int32(index + 1), text: text))
        }
        if records.count > visibleCount {
            entries.append(LocalHistoryListEntry(stableId: Int32(entries.count), text: "Показать ещё \(min(200, records.count - visibleCount))", loadMore: true))
        }
        if let message, let local = message.attributes.compactMap({ $0 as? LocalMessageStateAttribute }).first, !local.previousTexts.isEmpty {
            let start = Int32(entries.count + 1)
            for (index, text) in local.previousTexts.enumerated() {
                entries.append(LocalHistoryListEntry(stableId: start + Int32(index), text: "Версия \(index + 1)\n\n\(text.isEmpty ? "[Без текста]" : text)"))
            }
        }
        return (controllerState, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false), arguments))
    }
    |> afterDisposed { actions.dispose() }

    let controller = ItemListController(context: context, state: state)
    presentImpl = { [weak controller] alert in
        controller?.present(alert, in: .window(.root))
    }
    return controller
}
