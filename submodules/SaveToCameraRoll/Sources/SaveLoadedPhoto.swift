import Foundation
import Photos
import SwiftSignalKit
import TelegramCore
import AccountContext
import DeviceAccess

public enum SaveLoadedPhotoResult {
    case saved
    case unavailable
    case denied
    case failed

    public var message: String {
        switch self {
        case .saved: return "Фото сохранено в «Фото»."
        case .unavailable: return "Фото ещё не загружено или уже исчезло. Дождитесь загрузки и попробуйте снова."
        case .denied: return "Разрешите добавление фотографий в настройках iPhone."
        case .failed: return "Не удалось сохранить фото."
        }
    }
}

/// Snapshot the downloaded bytes before presenting the Photos permission prompt:
/// a disappearing message may expire while that prompt is open.
public func saveLoadedPhotoToCameraRoll(context: AccountContext, mediaReference: AnyMediaReference) -> Signal<SaveLoadedPhotoResult, NoError> {
    return Signal { subscriber in
        let resource: TelegramMediaResource?
        if let image = mediaReference.media as? TelegramMediaImage {
            resource = largestImageRepresentation(image.representations)?.resource
        } else if let file = mediaReference.media as? TelegramMediaFile, file.mimeType.hasPrefix("image/") {
            resource = file.resource
        } else {
            resource = nil
        }
        guard let resource,
              let path = context.engine.resources.completedResourcePath(id: EngineMediaResource.Id(resource.id)),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else {
            subscriber.putNext(.unavailable)
            subscriber.putCompletion()
            return EmptyDisposable
        }
        DeviceAccess.authorizeAccess(to: .mediaLibrary(.save), presentationData: context.sharedContext.currentPresentationData.with { $0 }, present: { controller, arguments in
            context.sharedContext.presentGlobalController(controller, arguments)
        }, openSettings: context.sharedContext.applicationBindings.openSettings, { authorized in
            guard authorized else {
                subscriber.putNext(.denied)
                subscriber.putCompletion()
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }, completionHandler: { success, _ in
                subscriber.putNext(success ? .saved : .failed)
                subscriber.putCompletion()
            })
        })
        return EmptyDisposable
    }
}
