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

func localMessageHistoryController(context: AccountContext) -> ViewController {
    let records = Promise<[LocalMessageHistoryEntry]>()
    records.set(context.engine.messages.localMessageHistory())
    let actions = DisposableSet()
    var presentImpl: ((ViewController) -> Void)?

    let state = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, records.get())
    |> map { presentationData, records -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let clear = ItemListNavigationButton(content: .text("Очистить"), style: .regular, enabled: !records.isEmpty, action: {
            presentImpl?(textAlertController(context: context, title: "Очистить историю?", text: "Сохранённые тексты правок и удалений будут удалены с этого устройства. Сообщения в чатах останутся.", actions: [
                TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
                TextAlertAction(type: .defaultDestructiveAction, title: "Очистить", action: {
                    actions.add((context.engine.messages.clearLocalMessageHistory()
                    |> deliverOnMainQueue).start())
                })
            ]))
        })
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("История сообщений"), leftNavigationButton: nil, rightNavigationButton: clear, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        var entries = [LocalHistoryListEntry(stableId: 0, text: "Локальные тексты сообщений до правок и удаления. Только полученные этой копией приложения. До 500 записей / 4 МБ; старые записи удаляются автоматически. Вложения, секретные и исчезающие сообщения не сохраняются.\n\nОнлайн, набор текста, прочтение и просмотры историй скрыты этой сборкой. Отправка сообщения, реакция или ответ на историю могут раскрыть активность.")]
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
                text += "\n\n[Было вложение; файл не сохранён]"
            }
            entries.append(LocalHistoryListEntry(stableId: Int32(index + 1), text: text))
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
