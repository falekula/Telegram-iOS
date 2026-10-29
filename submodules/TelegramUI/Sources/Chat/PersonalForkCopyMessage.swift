import Foundation
import Display
import TelegramCore
import AccountContext
import SwiftSignalKit
import TelegramPresentationData
import PresentationDataUtils
import LocalizedPeerData

// A protected chat cannot be forwarded with messages.forwardMessages. This is
// an explicitly labelled re-send of content the account already has locally.
func personalForkCanCopyMessage(_ message: EngineMessage, chatIsProtected: Bool) -> Bool {
    let raw = message._asMessage()
    let isGroup: Bool
    if raw.id.peerId.namespace == Namespaces.Peer.CloudGroup {
        isGroup = true
    } else if let channel = raw.peers[raw.id.peerId] as? TelegramChannel, case .group = channel.info {
        isGroup = true
    } else {
        isGroup = false
    }
    guard isGroup, chatIsProtected || raw.isCopyProtected(), !raw.flags.isSending, !raw.flags.contains(.Failed) else {
        return false
    }
    guard !raw.media.isEmpty || !raw.text.isEmpty else {
        return false
    }
    return raw.media.allSatisfy { $0 is TelegramMediaImage || $0 is TelegramMediaFile || $0 is TelegramMediaWebpage }
}

func personalForkCopyMessage(selfController: ChatControllerImpl, message: EngineMessage) {
    guard personalForkCanCopyMessage(message, chatIsProtected: selfController.presentationInterfaceState.copyProtectionEnabled) else {
        return
    }
    let context = selfController.context
    let raw = message._asMessage()
    let source = raw.peers[raw.id.peerId].flatMap(EnginePeer.init)?.compactDisplayTitle ?? "Группа"
    let author = message.author?.compactDisplayTitle ?? source
    let attribution = "Копия сообщения · \(source) · \(author)"

    // Large files are copied off the main queue. The new local resource makes
    // the normal uploader upload bytes, rather than reuse protected cloud IDs.
    let prepared: Signal<(ShareControllerSubject?, String?, String?), NoError> = Signal { subscriber in
        Queue.concurrentDefaultQueue().async {
            func copyResource(_ resource: TelegramMediaResource) -> LocalFileMediaResource? {
                let originalId = EngineMediaResource.Id(resource.id)
                guard context.engine.resources.completedResourcePath(id: originalId) != nil else {
                    return nil
                }
                let local = LocalFileMediaResource(fileId: Int64.random(in: Int64.min ... Int64.max))
                context.engine.resources.copyResourceData(from: originalId, to: EngineMediaResource.Id(local.id), synchronous: true)
                guard context.engine.resources.completedResourcePath(id: EngineMediaResource.Id(local.id)) != nil else {
                    return nil
                }
                return local
            }

            var mediaReference: AnyMediaReference?
            let caption = raw.text.isEmpty ? attribution : attribution + "\n\n" + raw.text
            for media in raw.media {
                if let image = media as? TelegramMediaImage {
                    guard let representation = image.representations.max(by: { Int64($0.dimensions.width) * Int64($0.dimensions.height) < Int64($1.dimensions.width) * Int64($1.dimensions.height) }), let resource = copyResource(representation.resource) else {
                        subscriber.putNext((nil, nil, "Сначала откройте фото и дождитесь его полной загрузки, затем повторите отправку копии."))
                        subscriber.putCompletion()
                        return
                    }
                    let localImage = TelegramMediaImage(imageId: EngineMedia.Id(namespace: Namespaces.Media.LocalImage, id: Int64.random(in: Int64.min ... Int64.max)), representations: [TelegramMediaImageRepresentation(dimensions: representation.dimensions, resource: resource, progressiveSizes: [], immediateThumbnailData: nil)], immediateThumbnailData: image.immediateThumbnailData, reference: nil, partialReference: nil, flags: [])
                    mediaReference = .standalone(media: localImage)
                    break
                } else if let file = media as? TelegramMediaFile {
                    guard let resource = copyResource(file.resource) else {
                        subscriber.putNext((nil, nil, "Сначала полностью скачайте файл, видео или аудио, затем повторите отправку копии."))
                        subscriber.putCompletion()
                        return
                    }
                    let previews = file.previewRepresentations.compactMap { representation -> TelegramMediaImageRepresentation? in
                        guard let resource = copyResource(representation.resource) else { return nil }
                        return TelegramMediaImageRepresentation(dimensions: representation.dimensions, resource: resource, progressiveSizes: [], immediateThumbnailData: nil)
                    }
                    let localFile = TelegramMediaFile(fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: Int64.random(in: Int64.min ... Int64.max)), partialReference: nil, resource: resource, previewRepresentations: previews, videoThumbnails: [], immediateThumbnailData: file.immediateThumbnailData, mimeType: file.mimeType, size: file.size, attributes: file.attributes, alternativeRepresentations: [])
                    mediaReference = .standalone(media: localFile)
                    break
                }
            }

            if let mediaReference {
                guard caption.utf16.count <= 1024 else {
                    subscriber.putNext((nil, nil, "Подпись вместе с источником длиннее 1024 знаков. Сохраните вложение и отправьте его отдельно, а текст скопируйте из сообщения."))
                    subscriber.putCompletion()
                    return
                }
                subscriber.putNext((.media(mediaReference, nil), caption, nil))
            } else {
                // Keep the original text intact: attribution is a separate note,
                // so a 4096-character message still fits Telegram's text limit.
                subscriber.putNext((.text(raw.text), attribution, nil))
            }
            subscriber.putCompletion()
        }
        return EmptyDisposable
    }
    let _ = (prepared |> deliverOnMainQueue).startStandalone(next: { [weak selfController] subject, presetText, error in
        guard let selfController else { return }
        if let error {
            selfController.present(textAlertController(context: context, updatedPresentationData: selfController.updatedPresentationData, title: "Отправить копию", text: error, actions: [TextAlertAction(type: .defaultAction, title: selfController.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
        } else if let subject {
            // Use the ordinary share screen: recipient selection, topics,
            // sending restrictions and paid-message confirmation stay intact.
            let controller = context.sharedContext.makeShareScreen(context: context, params: ShareControllerParams(subject: subject, presetText: presetText, externalShare: false, updatedPresentationData: selfController.updatedPresentationData, forcedActionTitle: "Отправить копию"))
            selfController.present(controller, in: .window(.root))
        }
    })
}
