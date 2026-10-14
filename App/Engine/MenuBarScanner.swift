import AppKit
import ApplicationServices

struct MenuBarApp: Equatable, Sendable, Identifiable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

@MainActor
final class MenuBarScanner {
    func scan(completion: @escaping @MainActor ([MenuBarApp]?) -> Void) {
        guard AXIsProcessTrusted() else { completion(nil); return }
        let ownID = Bundle.main.bundleIdentifier
        let candidates: [(String, String, pid_t)] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, id != ownID else { return nil }
            return (id, app.localizedName ?? id, app.processIdentifier)
        }
        Task.detached(priority: .utility) {
            var found: [String: String] = [:]
            for (id, name, pid) in candidates {
                let element = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(element, 0.25)
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &value) == .success {
                    found[id] = name
                }
            }
            let result = found.map { MenuBarApp(bundleID: $0.key, name: $0.value) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            await MainActor.run {
                completion(result)
            }
        }
    }
}
