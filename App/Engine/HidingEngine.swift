import Foundation
import OSLog
import SMHCore

@MainActor
final class HidingEngine {
    private let shim = SMHMenuBarShim()
    private let logger = Logger(subsystem: "dev.yili.smh", category: "engine")
    private(set) var activeList: [String]?
    private var pendingList: [String]?

    var isApplied: Bool { activeList != nil }
    var allowCount: Int { activeList?.count ?? 0 }

    func apply(list: [String], completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        if pendingList == nil && activeList == list {
            logger.info("no-op: allow list is already active")
            completion(nil)
            return
        }
        pendingList = list
        shim.applyAllowedBundleIDs(list, systemItems: AllowList.systemItems.map { NSNumber(value: $0) }) { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { completion(error); return }
                if let error {
                    self.logger.error("apply failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    self.activeList = list
                }
                if self.pendingList == list { self.pendingList = nil }
                completion(error)
            }
        }
    }

    func release() {
        logger.info("release all assertions")
        shim.releaseAll()
        activeList = nil
        pendingList = nil
    }
}
