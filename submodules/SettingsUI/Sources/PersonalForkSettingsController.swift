import Foundation
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import AccountContext

private final class PersonalForkArguments {
    let open: (Int32) -> Void
    init(open: @escaping (Int32) -> Void) { self.open = open }
}

private struct PersonalForkEntry: ItemListNodeEntry {
    let stableId: Int32
    let section: ItemListSectionId
    let title: String
    let detail: String
    let action: Bool
    static func < (lhs: PersonalForkEntry, rhs: PersonalForkEntry) -> Bool { lhs.stableId < rhs.stableId }
    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        if self.action {
            let arguments = arguments as! PersonalForkArguments
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: self.title, label: self.detail, labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, disclosureStyle: .arrow, action: { arguments.open(self.stableId) })
        }
        return ItemListTextItem(presentationData: presentationData, text: .plain(self.title + "\n" + self.detail), sectionId: self.section)
    }
}

public func personalForkSettingsController(context: AccountContext) -> ViewController {
    var push: ((ViewController) -> Void)?
    var currentLimits = LocalMessageHistoryLimits.defaultSettings
    var currentSendSettings = PersonalForkSendSettings.defaultSettings
    let arguments = PersonalForkArguments(open: { id in
        switch id {
        case 3: push?(personalForkSendSettingsController(context: context, initialSettings: currentSendSettings))
        case 4: push?(localMessageHistoryLimitsController(context: context, initialLimits: currentLimits))
        case 5: push?(localMessageHistoryController(context: context))
        case 7: push?(PersonalForkIconController(context: context))
        case 8: push?(themeSettingsController(context: context, focusOnItemTag: .icon))
        case 9: push?(personalForkNotificationStatusController(context: context))
        default: break
        }
    })
    let signal = combineLatest(context.sharedContext.presentationData, context.engine.messages.localMessageHistoryLimits(), context.engine.messages.personalForkSendSettings())
    |> deliverOnMainQueue
    |> map { presentationData, limits, sendSettings -> (ItemListControllerState, (ItemListNodeState, Any)) in
        currentLimits = limits
        currentSendSettings = sendSettings
        let entries = [
            PersonalForkEntry(stableId: 0, section: 0, title: "Скрытие онлайна включено", detail: "Отправка с задержкой, таймер — над чатом. Постоянный офлайн не гарантирован. В секретных чатах отправка отключена.", action: false),
            PersonalForkEntry(stableId: 1, section: 0, title: "Набор и прочтение скрыты", detail: "Включено всегда. Новая расшифровка входящих голосовых отключена.", action: false),
            PersonalForkEntry(stableId: 2, section: 0, title: "Истории без отметки", detail: "Ответы и реакции видны автору.", action: false),
            PersonalForkEntry(stableId: 3, section: 0, title: "Задержка отправки", detail: "\(sendSettings.delaySeconds) с", action: true),
            PersonalForkEntry(stableId: 4, section: 1, title: "Лимиты истории", detail: "Журнал: \(limits.recordCount) записей · \(limits.megabytes) МБ", action: true),
            PersonalForkEntry(stableId: 5, section: 1, title: "История и очистка", detail: "Правки и удаления из личных чатов", action: true),
            PersonalForkEntry(stableId: 6, section: 1, title: "Метки в чате", detail: "Корзина — удалено, карандаш — изменено. Прошлый текст — в меню сообщения.", action: false),
            PersonalForkEntry(stableId: 7, section: 2, title: "Своя иконка", detail: "Фото для ярлыка iOS", action: true),
            PersonalForkEntry(stableId: 8, section: 2, title: "Иконка приложения", detail: "Встроенные варианты", action: true),
            PersonalForkEntry(stableId: 9, section: 3, title: "Уведомления", detail: "Разрешения и доставка", action: true)
        ]
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("xxxgram"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        return (state, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false), arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    push = { [weak controller] next in controller?.push(next) }
    return controller
}
