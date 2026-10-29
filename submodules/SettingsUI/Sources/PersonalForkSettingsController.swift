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
    let status = ValuePromise<String>("Нажмите, чтобы применить настройку сервера", ignoreRepeated: true)
    let disposable = MetaDisposable()
    var push: ((ViewController) -> Void)?
    let arguments = PersonalForkArguments(open: { id in
        switch id {
        case 0:
            status.set("Применяем…")
            disposable.set((context.engine.privacy.applyPersonalForkPrivacy() |> deliverOnMainQueue).start(next: { success in
                status.set(success ? "Сервер принял «Никто» и статус офлайн" : "Нет подтверждения сервера. Нажмите ещё раз")
            }))
        case 3: push?(localMessageHistoryController(context: context))
        case 5: push?(PersonalForkIconController(context: context))
        case 6: push?(themeSettingsController(context: context, focusOnItemTag: .icon))
        default: break
        }
    })
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, status.get())
    |> map { presentationData, status -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let entries = [
            PersonalForkEntry(stableId: 0, section: 0, title: "Скрывать онлайн", detail: status, action: true),
            PersonalForkEntry(stableId: 1, section: 0, title: "✓ Набор текста и прочтение", detail: "Отправка этих сигналов отключена. На других устройствах прочитанное может остаться непрочитанным.", action: false),
            PersonalForkEntry(stableId: 2, section: 0, title: "✓ Просмотр историй", detail: "Отметка просмотра не отправляется. Ответы и реакции видны автору. Отправка сообщений может раскрывать онлайн.", action: false),
            PersonalForkEntry(stableId: 3, section: 1, title: "История правок и удалений", detail: "Просмотр и очистка локальных копий", action: true),
            PersonalForkEntry(stableId: 4, section: 1, title: "✓ Исчезающие фото", detail: "Откройте фото → ⋯ → Сохранить изображение. Полученные фото остаются доступны локально; ранее исчезнувшие файлы восстановить нельзя.", action: false),
            PersonalForkEntry(stableId: 5, section: 2, title: "Своя картинка для иконки", detail: "Выбор фото и создание ярлыка через Команды iOS", action: true),
            PersonalForkEntry(stableId: 6, section: 2, title: "Встроенные иконки приложения", detail: "Варианты, включённые в эту сборку", action: true)
        ]
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Настройки форка"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        return (state, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false), arguments))
    }
    |> afterDisposed { disposable.dispose() }
    let controller = ItemListController(context: context, state: signal)
    push = { [weak controller] next in controller?.push(next) }
    return controller
}
