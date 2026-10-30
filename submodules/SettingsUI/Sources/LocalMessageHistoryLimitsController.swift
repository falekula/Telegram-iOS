import Foundation
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import AccountContext
import AlertUI
import PresentationDataUtils

private struct HistoryLimitsDraft: Equatable {
    var records: String
    var megabytes: String
    var saving: Bool = false

    var limits: LocalMessageHistoryLimits? {
        guard let records = Int(self.records), LocalMessageHistoryLimits.recordRange.contains(records),
              let megabytes = Int(self.megabytes), LocalMessageHistoryLimits.megabyteRange.contains(megabytes) else { return nil }
        return LocalMessageHistoryLimits(recordCount: records, megabytes: megabytes)
    }
}

private final class HistoryLimitsArguments {
    let update: (Int32, String) -> Void
    init(update: @escaping (Int32, String) -> Void) { self.update = update }
}

private struct HistoryLimitsEntry: ItemListNodeEntry {
    let stableId: Int32
    let text: String
    let value: String?
    let enabled: Bool
    var section: ItemListSectionId { return self.stableId < 2 ? 0 : 1 }
    static func < (lhs: Self, rhs: Self) -> Bool { return lhs.stableId < rhs.stableId }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        if let value = self.value {
            let arguments = arguments as! HistoryLimitsArguments
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: self.text, textColor: presentationData.theme.list.itemPrimaryTextColor), text: value, placeholder: self.stableId == 0 ? "500" : "4", type: .number, spacing: 10.0, clearType: .onFocus, enabled: self.enabled, selectAllOnFocus: true, sectionId: self.section, textUpdated: { value in
                arguments.update(self.stableId, value)
            }, shouldUpdateText: { value in
                return value.utf8.count <= 6 && value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 })
            }, action: {})
        }
        return ItemListTextItem(presentationData: presentationData, text: .plain(self.text), sectionId: self.section)
    }
}

public func localMessageHistoryLimitsController(context: AccountContext, initialLimits: LocalMessageHistoryLimits) -> ViewController {
    let draft = ValuePromise(HistoryLimitsDraft(records: String(initialLimits.recordCount), megabytes: String(initialLimits.megabytes)), ignoreRepeated: true)
    let draftValue = Atomic(value: HistoryLimitsDraft(records: String(initialLimits.recordCount), megabytes: String(initialLimits.megabytes)))
    let updateDraft: ((inout HistoryLimitsDraft) -> Void) -> Void = { f in
        draft.set(draftValue.modify { value in
            var value = value
            f(&value)
            return value
        })
    }
    let actions = DisposableSet()
    var presentImpl: ((ViewController) -> Void)?
    var finishImpl: (() -> Void)?
    let arguments = HistoryLimitsArguments(update: { id, value in
        // Keep invalid/empty drafts editable; never persist a partial number while typing.
        guard value.utf8.count <= 6, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return }
        updateDraft { state in
            if id == 0 { state.records = value } else { state.megabytes = value }
        }
    })
    let state = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, draft.get())
    |> map { presentationData, draft -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let save = ItemListNavigationButton(content: .text(draft.saving ? "Сохранение…" : presentationData.strings.Common_Save), style: .bold, enabled: !draft.saving && draft.limits != nil && draft.limits != initialLimits, action: {
            let current = draftValue.with { $0 }
            guard let limits = current.limits, !current.saving else { return }
            let apply: () -> Void = {
                guard !draftValue.with({ $0.saving }) else { return }
                updateDraft { $0.saving = true }
                actions.add((context.engine.messages.updateLocalMessageHistoryLimits(limits)
                |> deliverOnMainQueue).start(next: { saved in
                    if saved {
                        finishImpl?()
                    } else {
                        updateDraft { $0.saving = false }
                        presentImpl?(textAlertController(context: context, title: "Не удалось сохранить", text: "Значения не изменены. Попробуйте ещё раз.", actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]))
                    }
                }))
            }
            if limits.recordCount < initialLimits.recordCount || limits.megabytes < initialLimits.megabytes {
                presentImpl?(textAlertController(context: context, title: "Уменьшить журнал?", text: "Старые записи сверх лимита удалятся навсегда. Копии в чатах останутся.", actions: [
                    TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
                    TextAlertAction(type: .defaultDestructiveAction, title: "Применить", action: apply)
                ]))
            } else {
                apply()
            }
        })
        let entries = [
            HistoryLimitsEntry(stableId: 0, text: "Записей", value: draft.records, enabled: !draft.saving),
            HistoryLimitsEntry(stableId: 1, text: "Память, МБ", value: draft.megabytes, enabled: !draft.saving),
            HistoryLimitsEntry(stableId: 2, text: draft.limits == nil ? "Введите 1–10 000 записей и 1–64 МБ." : "1–10 000 записей · 1–64 МБ. Для этого аккаунта.", value: nil, enabled: true),
            HistoryLimitsEntry(stableId: 3, text: "При заполнении журнала старые записи заменяются новыми. Копии в чатах и до 30 версий текста хранятся отдельно.", value: nil, enabled: true)
        ]
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Лимиты истории"), leftNavigationButton: nil, rightNavigationButton: save, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        return (controllerState, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false), arguments))
    }
    |> afterDisposed { actions.dispose() }
    let controller = ItemListController(context: context, state: state)
    presentImpl = { [weak controller] alert in controller?.present(alert, in: .window(.root)) }
    finishImpl = { [weak controller] in
        let _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
    }
    return controller
}
