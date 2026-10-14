import Foundation
import OSLog
import SMHCore

/// The parts of SMHMenuBarShim the engine uses, so HidingEngineTests.swift can pass a fake.
protocol MenuBarShimming: AnyObject {
    func applyAllowedBundleIDs(_ ids: [String], systemItems: [NSNumber], completion: @escaping @Sendable (Error?) -> Void)
    func releaseAll()
}

@MainActor
final class HidingEngine {
    private let shim: any MenuBarShimming
    private let logger = Logger(subsystem: "dev.yili.smh", category: "engine")
    private(set) var activeList: [String]?
    /// Each apply gets a number. A request leaves this set only when its own completion runs,
    /// so a superseded duplicate of the same list cannot mark a newer request as finished.
    private var pendingTokens: Set<Int> = []
    private var lastToken = 0
    private var applyCounter = ApplyCounter()

    init(shim: any MenuBarShimming) { self.shim = shim }

    var isApplied: Bool { activeList != nil }
    var allowCount: Int { activeList?.count ?? 0 }
    var applyCount: Int { applyCounter.value }

    /// `force` sends the list even when it is already active, after events that may have dropped the
    /// assertion (wake, display change, MenuBarAgent restart). Ordinary changes skip an unchanged list.
    func apply(list: [String], force: Bool = false, completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        if !force && pendingTokens.isEmpty && activeList == list {
            logger.info("no-op: allow list is already active")
            completion(nil)
            return
        }
        lastToken += 1
        let token = lastToken
        pendingTokens.insert(token)
        shim.applyAllowedBundleIDs(list, systemItems: AllowList.systemItems.map { NSNumber(value: $0) }) { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { completion(error); return }
                self.pendingTokens.remove(token)
                if let error {
                    self.logger.error("apply \(token) failed: \(error.localizedDescription, privacy: .public)")
                } else if token == self.lastToken {
                    self.activeList = list
                    self.applyCounter.recordSuccess()
                } else {
                    // The shim lets only the newest request succeed; log it if that ever changes.
                    self.logger.error("apply \(token) succeeded after newer apply \(self.lastToken); ignored")
                }
                completion(error)
            }
        }
    }

    func release() {
        logger.info("release all assertions")
        shim.releaseAll()
        activeList = nil
        pendingTokens.removeAll()
    }
}
