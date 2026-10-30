import Foundation
import UIKit
import UserNotifications
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AccountContext

private struct PersonalForkNotificationStatus: Equatable {
    let permission: String
    let canRequest: Bool
    let registration: String
    let details: String
}

private func personalForkNotificationStatus() -> Signal<PersonalForkNotificationStatus, NoError> {
    return Signal { subscriber in
        let refresh: () -> Void = {
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                DispatchQueue.main.async {
                    let permission: String
                    switch settings.authorizationStatus {
                    case .authorized: permission = "Разрешены в iOS"
                    case .provisional: permission = "Тихая доставка — без баннера и звука"
                    case .ephemeral: permission = "Разрешены временно"
                    case .denied: permission = "Запрещены в настройках iOS"
                    case .notDetermined: permission = "Разрешение ещё не запрошено"
                    @unknown default: permission = "Статус разрешения неизвестен"
                    }
                    let registration: String
                    let details: String
                    if UIApplication.shared.isRegisteredForRemoteNotifications {
                        registration = "Устройство зарегистрировано в Apple"
                        details = "Регистрация ещё не подтверждает доставку от Telegram. Проверьте уведомления чата, режим Фокусирование и отправьте сообщение с другого аккаунта, свернув xxxgram. «Избранное» не подходит для проверки."
                    } else if UserDefaults.standard.string(forKey: "xxxgram.push-registration-failure") == "missing-entitlement" {
                        registration = "Текущая подпись не поддерживает push"
                        details = "Apple отклонила регистрацию: в подписи приложения нет разрешения на push. Уведомления при закрытом приложении с этой подписью недоступны. Нужны подходящий профиль подписи и настройка доставки push для приложения. Разрешение в iOS само по себе это не исправит."
                    } else if UserDefaults.standard.string(forKey: "xxxgram.push-registration-failure") != nil {
                        registration = "Не удалось зарегистрироваться в Apple"
                        details = "Проверьте подключение к интернету и повторите регистрацию. Если ошибка остаётся, нужно проверить подпись приложения и настройку доставки push."
                    } else {
                        registration = "Push ещё не зарегистрирован"
                        details = "Разрешите уведомления и повторите регистрацию. Для фоновой доставки требуется поддержка push в подписи приложения и настройка отправки со стороны сервера."
                    }
                    subscriber.putNext(PersonalForkNotificationStatus(permission: permission, canRequest: settings.authorizationStatus == .notDetermined, registration: registration, details: details))
                }
            }
        }
        refresh()
        let foreground = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in refresh() }
        let registration = NotificationCenter.default.addObserver(forName: Notification.Name("xxxgram.push-registration-status"), object: nil, queue: .main) { _ in refresh() }
        return ActionDisposable {
            NotificationCenter.default.removeObserver(foreground)
            NotificationCenter.default.removeObserver(registration)
        }
    }
    |> distinctUntilChanged
}

private final class PersonalForkNotificationArguments {
    let action: (Int32) -> Void
    init(action: @escaping (Int32) -> Void) { self.action = action }
}

private struct PersonalForkNotificationEntry: ItemListNodeEntry {
    let stableId: Int32
    let section: ItemListSectionId
    let title: String
    let detail: String
    let actionable: Bool

    static func < (lhs: PersonalForkNotificationEntry, rhs: PersonalForkNotificationEntry) -> Bool { lhs.stableId < rhs.stableId }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        if self.actionable {
            let arguments = arguments as! PersonalForkNotificationArguments
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: self.title, label: self.detail, labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, disclosureStyle: .arrow, action: { arguments.action(self.stableId) })
        }
        return ItemListTextItem(presentationData: presentationData, text: .plain(self.title + "\n" + self.detail), sectionId: self.section)
    }
}

func personalForkNotificationStatusController(context: AccountContext) -> ViewController {
    var push: ((ViewController) -> Void)?
    let arguments = PersonalForkNotificationArguments(action: { id in
        switch id {
        case 2:
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                DispatchQueue.main.async {
                    if settings.authorizationStatus == .notDetermined {
                        context.sharedContext.applicationBindings.registerForNotifications { _ in
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(name: Notification.Name("xxxgram.push-registration-status"), object: nil)
                            }
                        }
                    } else {
                        context.sharedContext.applicationBindings.openSettings()
                    }
                }
            }
        case 3:
            UIApplication.shared.registerForRemoteNotifications()
        case 4:
            push?(notificationsAndSoundsController(context: context, exceptionsList: nil))
        default: break
        }
    })
    let state = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, personalForkNotificationStatus())
    |> map { presentationData, status -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let entries = [
            PersonalForkNotificationEntry(stableId: 0, section: 0, title: "Разрешение iOS", detail: status.permission, actionable: false),
            PersonalForkNotificationEntry(stableId: 1, section: 1, title: status.registration, detail: status.details, actionable: false),
            PersonalForkNotificationEntry(stableId: 2, section: 2, title: status.canRequest ? "Разрешить уведомления" : "Открыть настройки iOS", detail: "Баннеры, звук и экран блокировки", actionable: true),
            PersonalForkNotificationEntry(stableId: 3, section: 2, title: "Повторить регистрацию", detail: "Проверить подключение к Apple", actionable: true),
            PersonalForkNotificationEntry(stableId: 4, section: 2, title: "Чаты и звуки", detail: "Настройки уведомлений этого аккаунта", actionable: true)
        ]
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Уведомления на iPhone"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        return (controllerState, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false), arguments))
    }
    let controller = ItemListController(context: context, state: state)
    push = { [weak controller] next in controller?.push(next) }
    return controller
}
