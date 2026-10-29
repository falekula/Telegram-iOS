import Foundation
internal import TelegramApi
import Postbox
import SwiftSignalKit
import MtProtoKit

private typealias SignalKitTimer = SwiftSignalKit.Timer

private struct PersonalForkPublicPresenceMigration: Codable {}
private let personalForkPublicPresenceKey = ValueBoxKey("xxxgram.public-presence-migration.v1")

private final class AccountPresenceManagerImpl {
    private let queue: Queue
    private let network: Network
    let isPerformingUpdate = ValuePromise<Bool>(false, ignoreRepeated: true)
    
    private var shouldKeepOnlinePresenceDisposable: Disposable?
    private let currentRequestDisposable = MetaDisposable()
    private let privacySettingsDisposable = MetaDisposable()
    private var onlineTimer: SignalKitTimer?
    
    private var wasOnline: Bool = false
    
    init(queue: Queue, shouldKeepOnlinePresence: Signal<Bool, NoError>, network: Network, postbox: Postbox) {
        self.queue = queue
        self.network = network
        // The owner explicitly requested public last-seen instead of the prior
        // build's Nobody setting. Migrate once, only marking success after the
        // server accepts it; later manual changes remain untouched.
        self.privacySettingsDisposable.set((postbox.transaction { transaction in
            return transaction.getPreferencesEntry(key: personalForkPublicPresenceKey) == nil
        } |> mapToSignal { needsMigration -> Signal<Void, NoError> in
            guard needsMigration else { return .complete() }
            return (network.request(Api.functions.account.setPrivacy(key: .inputPrivacyKeyStatusTimestamp, rules: [.inputPrivacyValueAllowAll])) |> retryRequest)
            |> mapToSignal { _ in
                return postbox.transaction { transaction in
                    transaction.setPreferencesEntry(key: personalForkPublicPresenceKey, value: PreferencesEntry(PersonalForkPublicPresenceMigration()))
                }
            }
        }).start())
        
        self.shouldKeepOnlinePresenceDisposable = (shouldKeepOnlinePresence
        |> distinctUntilChanged
        |> deliverOn(self.queue)).start(next: { [weak self] value in
            guard let `self` = self else {
                return
            }
            if self.wasOnline != value {
                self.wasOnline = value
                self.updatePresence(value)
            }
        })
    }
    
    deinit {
        assert(self.queue.isCurrent())
        self.shouldKeepOnlinePresenceDisposable?.dispose()
        self.currentRequestDisposable.dispose()
        self.privacySettingsDisposable.dispose()
        self.onlineTimer?.invalidate()
    }
    
    private func updatePresence(_ isOnline: Bool) {
        if SideloadPrivacy.hideOnline {
            // Do not continually send offline either: it can move the server's
            // last-seen date. The network layer also blocks alternative callers.
            self.onlineTimer?.invalidate()
            self.onlineTimer = nil
            self.isPerformingUpdate.set(false)
            return
        }
        let request: Signal<Api.Bool, MTRpcError>
        if isOnline {
            let timer = SignalKitTimer(timeout: 30.0, repeat: false, completion: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.updatePresence(true)
            }, queue: self.queue)
            self.onlineTimer = timer
            timer.start()
            request = self.network.request(Api.functions.account.updateStatus(offline: .boolFalse))
        } else {
            self.onlineTimer?.invalidate()
            self.onlineTimer = nil
            request = self.network.request(Api.functions.account.updateStatus(offline: .boolTrue))
        }
        self.isPerformingUpdate.set(true)
        self.currentRequestDisposable.set((request
        |> `catch` { _ -> Signal<Api.Bool, NoError> in
            return .single(.boolFalse)
        }
        |> deliverOn(self.queue)).start(completed: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.isPerformingUpdate.set(false)
        }))
    }
}

final class AccountPresenceManager {
    private let queue = Queue()
    private let impl: QueueLocalObject<AccountPresenceManagerImpl>
    
    init(shouldKeepOnlinePresence: Signal<Bool, NoError>, network: Network, postbox: Postbox) {
        let queue = self.queue
        self.impl = QueueLocalObject(queue: self.queue, generate: {
            return AccountPresenceManagerImpl(queue: queue, shouldKeepOnlinePresence: shouldKeepOnlinePresence, network: network, postbox: postbox)
        })
    }
    
    func isPerformingUpdate() -> Signal<Bool, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.isPerformingUpdate.get().start(next: { value in
                    subscriber.putNext(value)
                }))
            }
            return disposable
        }
    }
}
