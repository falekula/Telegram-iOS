import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import SaveToCameraRoll
import SaveProgressScreen
import UndoUI

func presentVideoSave(context: AccountContext, controller: ViewController, userLocation: MediaResourceUserLocation, mediaReference: AnyMediaReference) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let screen = SaveProgressScreen(context: context, content: .progress("Сохраняем видео…", 0.0))
    controller.present(screen, in: .current)
    let disposable = MetaDisposable()
    screen.cancelled = {
        disposable.dispose()
    }
    disposable.set((saveVideoToCameraRoll(context: context, userLocation: userLocation, mediaReference: mediaReference)
    |> deliverOnMainQueue).start(next: { [weak screen, weak controller] state in
        guard let screen else { return }
        switch state {
        case let .progress(value):
            screen.content = .progress("Сохраняем видео…", value)
        case let .result(result):
            screen.dismiss(completion: { [weak controller] in
                controller?.present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: result.message, timeout: 3.0, customUndoText: nil), elevatedLayout: false, animateInAsReplacement: false, action: { _ in false }), in: .window(.root))
            })
        }
    }))
}
