import Foundation
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import AccountContext
import AlertUI
import PresentationDataUtils

private struct PersonalForkSendDraft: Equatable {
    var text: String
    var saving: Bool = false
    var seconds: Int32? {
        guard let value = Int32(self.text), value >= PersonalForkSendSettings.minimumDelaySeconds, value <= PersonalForkSendSettings.maximumDelaySeconds else { return nil }
        return value
    }
}

private final class PersonalForkSendArguments {
    let update: (String) -> Void
    init(update: @escaping (String) -> Void) { self.update = update }
}

private struct PersonalForkSendEntry: ItemListNodeEntry {
    let stableId: Int32
    let text: String
    let value: String?
    let enabled: Bool
    var section: ItemListSectionId { return 0 }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.stableId < rhs.stableId }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        if let value = self.value {
            let arguments = arguments as! PersonalForkSendArguments
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: self.text, textColor: presentationData.theme.list.itemPrimaryTextColor), text: value, placeholder: "15", type: .number, spacing: 10.0, clearType: .onFocus, enabled: self.enabled, selectAllOnFocus: true, sectionId: self.section, textUpdated: arguments.update, shouldUpdateText: { text in
                return text.utf8.count <= 3 && text.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
            }, action: {})
        }
        return ItemListTextItem(presentationData: presentationData, text: .plain(self.text), sectionId: self.section)
    }
}

public func personalForkSendSettingsController(context: AccountContext, initialSettings: PersonalForkSendSettings) -> ViewController {
    let initialDraft = PersonalForkSendDraft(text: String(initialSettings.delaySeconds))
    let stateValue = Atomic(value: initialDraft)
    let statePromise = ValuePromise(initialDraft, ignoreRepeated: true)
    let update: ((inout PersonalForkSendDraft) -> Void) -> Void = { f in
        statePromise.set(stateValue.modify { state in
            var state = state
            f(&state)
            return state
        })
    }
    let actions = DisposableSet()
    var presentImpl: ((ViewController) -> Void)?
    var finishImpl: (() -> Void)?
    let arguments = PersonalForkSendArguments(update: { text in
        update { $0.text = text }
    })
    let state = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, statePromise.get())
    |> map { presentationData, draft -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let save = ItemListNavigationButton(content: .text(draft.saving ? "Сохранение…" : presentationData.strings.Common_Save), style: .bold, enabled: !draft.saving && draft.seconds != nil && draft.seconds != initialSettings.delaySeconds, action: {
            let current = stateValue.with { $0 }
            guard let seconds = current.seconds, !current.saving else { return }
            update { $0.saving = true }
            actions.add((context.engine.messages.updatePersonalForkSendSettings(delaySeconds: seconds)
            |> deliverOnMainQueue).start(next: { saved in
                if saved {
                    finishImpl?()
                } else {
                    update { $0.saving = false }
                    presentImpl?(textAlertController(context: context, title: "Не удалось сохранить", text: "Попробуйте ещё раз.", actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]))
                }
            }))
        })
        let entries = [
            PersonalForkSendEntry(stableId: 0, text: "Секунд", value: draft.text, enabled: !draft.saving),
            PersonalForkSendEntry(stableId: 1, text: draft.seconds == nil ? "Введите от 15 до 300 секунд." : "15–300 с. Для новых сообщений и повторов. Большие файлы могут ждать дольше.", value: nil, enabled: true)
        ]
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Задержка отправки"), leftNavigationButton: nil, rightNavigationButton: save, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
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
