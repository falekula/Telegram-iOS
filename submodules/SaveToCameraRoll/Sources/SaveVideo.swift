import Foundation
import Photos
import SwiftSignalKit
import TelegramCore
import AccountContext
import DeviceAccess

public enum SaveVideoResult {
    case saved
    case unavailable
    case denied
    case failed

    public var message: String {
        switch self {
        case .saved: return "Видео сохранено в «Фото»."
        case .unavailable: return "Видео недоступно. Проверьте загрузку и повторите."
        case .denied: return "Разрешите добавление в «Фото» в настройках iPhone."
        case .failed: return "Не удалось сохранить видео. Проверьте формат и свободное место."
        }
    }
}

public enum SaveVideoState {
    case progress(Float)
    case result(SaveVideoResult)
}

/// Downloads the complete video and reports the result of exporting it to Photos.
public func saveVideoToCameraRoll(context: AccountContext, userLocation: MediaResourceUserLocation, mediaReference: AnyMediaReference) -> Signal<SaveVideoState, NoError> {
    guard let file = mediaReference.media as? TelegramMediaFile,
          file.isVideo || file.isInstantVideo || file.mimeType.hasPrefix("video/") else {
        return .single(.result(.unavailable))
    }
    let signal = Signal<SaveVideoState, NoError> { subscriber in
        let cancelled = Atomic<Bool>(value: false)
        let exporting = Atomic<Bool>(value: false)
        let lastProgress = Atomic<Float>(value: -1.0)
        let timer = SwiftSignalKit.Timer(timeout: 180.0, repeat: false, completion: {
            subscriber.putNext(.result(.unavailable))
            subscriber.putCompletion()
        }, queue: Queue.mainQueue())
        timer.start()
        let temporaryPath = NSTemporaryDirectory() + UUID().uuidString + (file.mimeType == "video/quicktime" ? ".mov" : ".mp4")
        let download = (fetchMediaData(context: context, userLocation: userLocation, mediaReference: mediaReference)
        |> deliverOnMainQueue).start(next: { state, _ in
            guard !cancelled.with({ $0 }), !exporting.with({ $0 }) else { return }
            switch state {
            case let .progress(value):
                if value > lastProgress.swap(value) {
                    timer.invalidate()
                    timer.start()
                }
                subscriber.putNext(.progress(min(0.95, max(0.0, value) * 0.95)))
            case let .data(data):
                guard data.isComplete, !exporting.swap(true) else { return }
                timer.invalidate()
                timer.start()
                subscriber.putNext(.progress(0.95))
                Queue.concurrentDefaultQueue().async {
                    do {
                        try FileManager.default.copyItem(atPath: data.path, toPath: temporaryPath)
                    } catch {
                        try? FileManager.default.removeItem(atPath: temporaryPath)
                        subscriber.putNext(.result(.failed))
                        subscriber.putCompletion()
                        return
                    }
                    Queue.mainQueue().async {
                        guard !cancelled.with({ $0 }) else {
                            try? FileManager.default.removeItem(atPath: temporaryPath)
                            return
                        }
                        DeviceAccess.authorizeAccess(to: .mediaLibrary(.save), presentationData: context.sharedContext.currentPresentationData.with { $0 }, present: { controller, arguments in
                            context.sharedContext.presentGlobalController(controller, arguments)
                        }, openSettings: context.sharedContext.applicationBindings.openSettings, { authorized in
                            guard authorized, !cancelled.with({ $0 }) else {
                                try? FileManager.default.removeItem(atPath: temporaryPath)
                                if !cancelled.with({ $0 }) {
                                    subscriber.putNext(.result(.denied))
                                    subscriber.putCompletion()
                                }
                                return
                            }
                            timer.invalidate()
                            let created = Atomic<Bool>(value: false)
                            PHPhotoLibrary.shared().performChanges({
                                let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: URL(fileURLWithPath: temporaryPath))
                                let _ = created.swap(request != nil)
                            }, completionHandler: { success, _ in
                                try? FileManager.default.removeItem(atPath: temporaryPath)
                                guard !cancelled.with({ $0 }) else { return }
                                subscriber.putNext(.result(success && created.with({ $0 }) ? .saved : .failed))
                                subscriber.putCompletion()
                            })
                        })
                    }
                }
            }
        }, completed: {
            if !exporting.with({ $0 }) {
                subscriber.putNext(.result(.unavailable))
                subscriber.putCompletion()
            }
        })
        return ActionDisposable {
            let _ = cancelled.swap(true)
            timer.invalidate()
            download.dispose()
        }
    }
    return signal
    |> take(until: { state in
        if case .result = state {
            return SignalTakeAction(passthrough: true, complete: true)
        }
        return SignalTakeAction(passthrough: true, complete: false)
    })
}
