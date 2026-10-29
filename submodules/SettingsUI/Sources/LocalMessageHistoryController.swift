import Foundation
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import AccountContext
import AlertUI
import PresentationDataUtils

private struct LocalHistoryListEntry: ItemListNodeEntry {
    let stableId: Int32
    let text: String

    var section: ItemListSectionId { return self.stableId }

    static func < (lhs: LocalHistoryListEntry, rhs: LocalHistoryListEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        return ItemListTextItem(presentationData: presentationData, text: .plain(self.text), sectionId: self.section)
    }
}

public func localMessageHistoryController(context: AccountContext, message: EngineMessage? = nil) -> ViewController {
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

    let state = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, records.get(), currentMessage)
    |> map { presentationData, records, message -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let clear = ItemListNavigationButton(content: .text("Очистить"), style: .regular, enabled: true, action: {
            presentImpl?(textAlertController(context: context, title: "Очистить историю?", text: "Вся локальная история будет очищена. Сохранённые копии удалённых сообщений и исчезающих фото пропадут из чатов. Обычные сообщения останутся.", actions: [
                TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
                TextAlertAction(type: .defaultDestructiveAction, title: "Очистить", action: {
                    actions.add((context.engine.messages.clearLocalMessageHistory()
                    |> deliverOnMainQueue).start())
                })
            ]))
        })
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Личная история"), leftNavigationButton: nil, rightNavigationButton: clear, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        var entries = [LocalHistoryListEntry(stableId: 0, text: "Только личные переписки. Удалённые сообщения остаются в чате полупрозрачными с корзиной; у правок появляется карандаш. Зажмите сообщение — прошлый текст и его копирование доступны прямо в меню. До 30 версий на сообщение; журнал ниже — до 500 записей / 4 МБ. Очистка убирает локальные копии, а обычные сообщения на сервере сохраняет. Загруженные файлы можно отдельно очистить в Данные и память → Использование памяти.")]
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        if records.isEmpty {
            entries.append(LocalHistoryListEntry(stableId: 1, text: "История пуста. Новые правки и удаления появятся здесь после получения обновлений."))
        }
        for (index, record) in records.enumerated() {
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
        if let message, let local = message.attributes.compactMap({ $0 as? LocalMessageStateAttribute }).first, !local.previousTexts.isEmpty {
            let start = Int32(entries.count + 1)
            for (index, text) in local.previousTexts.enumerated() {
                entries.append(LocalHistoryListEntry(stableId: start + Int32(index), text: "Версия \(index + 1)\n\n\(text.isEmpty ? "[Без текста]" : text)"))
            }
        }
        return (controllerState, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false), ()))
    }
    |> afterDisposed { actions.dispose() }

    let controller = ItemListController(context: context, state: state)
    presentImpl = { [weak controller] alert in
        controller?.present(alert, in: .window(.root))
    }
    return controller
}
