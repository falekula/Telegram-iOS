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
    let arguments = PersonalForkArguments(open: { id in
        switch id {
        case 3: push?(localMessageHistoryLimitsController(context: context, initialLimits: currentLimits))
        case 4: push?(localMessageHistoryController(context: context))
        case 6: push?(PersonalForkIconController(context: context))
        case 7: push?(themeSettingsController(context: context, focusOnItemTag: .icon))
        case 8: push?(personalForkNotificationStatusController(context: context))
        default: break
        }
    })
    let signal = combineLatest(context.sharedContext.presentationData, context.engine.messages.localMessageHistoryLimits())
    |> deliverOnMainQueue
    |> map { presentationData, limits -> (ItemListControllerState, (ItemListNodeState, Any)) in
        currentLimits = limits
        let entries = [
            PersonalForkEntry(stableId: 0, section: 0, title: "Онлайн — скрытие включено", detail: "Приложение не отправляет обновления статуса. Текст отправляется с задержкой от 12 секунд, медиа — после загрузки с учётом размера. Панель над чатом показывает очередь и отсчёт; нажмите на неё, чтобы изменить или отменить сообщение. Секретные чаты и некоторые боты не поддерживают этот способ: отправка покажет ошибку. Точную дату последней активности на сервере заморозить нельзя.", action: false),
            PersonalForkEntry(stableId: 1, section: 0, title: "Набор текста и прочтение — отключены", detail: "Работает сразу, без переключателей. Отметки прочтения не отправляются; другие устройства могут показывать сообщения непрочитанными. Новая серверная расшифровка входящих голосовых отключена, поскольку она раскрывает прослушивание.", action: false),
            PersonalForkEntry(stableId: 2, section: 0, title: "Просмотр историй — без отметки", detail: "Ответы и реакции остаются видны автору.", action: false),
            PersonalForkEntry(stableId: 3, section: 1, title: "Лимиты истории", detail: "Журнал: \(limits.recordCount) записей · \(limits.megabytes) МБ", action: true),
            PersonalForkEntry(stableId: 4, section: 1, title: "Личная история и очистка", detail: "Локальные копии только из личных переписок", action: true),
            PersonalForkEntry(stableId: 5, section: 1, title: "Всё рядом с сообщением", detail: "Корзина — удалено, карандаш — есть прошлый текст. Зажмите сообщение, чтобы прочитать или скопировать прошлую версию. У исчезающих вложений показан исходный срок: один просмотр или секунды. Фото и видео сохраняются из меню просмотрщика.", action: false),
            PersonalForkEntry(stableId: 6, section: 2, title: "Своя картинка для иконки", detail: "Выбор фото и создание ярлыка через Команды iOS", action: true),
            PersonalForkEntry(stableId: 7, section: 2, title: "Встроенные иконки приложения", detail: "Варианты, включённые в эту сборку", action: true),
            PersonalForkEntry(stableId: 8, section: 3, title: "Уведомления на iPhone", detail: "Проверить разрешение и поддержку push", action: true)
        ]
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("xxxgram"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        return (state, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false), arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    push = { [weak controller] next in controller?.push(next) }
    return controller
}
