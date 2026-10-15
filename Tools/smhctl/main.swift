import Foundation

// smhctl: drives SMH's debug control channel (see docs/debug-channel.md).
//
//   smhctl <cmd> [arg] [--timeout-ms 5000]
//
// Posts dev.yili.smh.debug.command with a fresh id, waits for the matching
// dev.yili.smh.debug.state reply on the main run loop, prints one line with
// every reply field except id, sorted by key, for example
//   allowCount=<..> applied=<..> hidden=<..> popover=<..> state=<..> trusted=<..>
// (a scan reply also has found=<..>) and exits 0, or prints TIMEOUT and exits 3. The observer is registered
// before posting so the reply cannot be missed. Foundation only.

func usageError(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    FileHandle.standardError.write("usage: smhctl <setHidden|setRevealSeconds|toggleApp|openPopover|closePopover|scan|reveal|pause|resume|state|quit> [arg] [--timeout-ms 5000]\n".data(using: .utf8)!)
    exit(2)
}

var tokens = Array(CommandLine.arguments.dropFirst())
guard let cmd = tokens.first, !cmd.hasPrefix("-") else {
    usageError("missing command")
}
tokens.removeFirst()

let commandsWithArg: Set<String> = ["setHidden", "setRevealSeconds", "toggleApp", "failNextApplies"]
let commandsWithoutArg: Set<String> = ["openPopover", "closePopover", "scan", "reveal", "pause", "resume", "state", "quit"]
guard commandsWithArg.contains(cmd) || commandsWithoutArg.contains(cmd) else {
    usageError("unknown command: \(cmd)")
}

var arg: String? = nil
var timeoutMs = 5000
var i = 0
while i < tokens.count {
    let token = tokens[i]
    if token == "--timeout-ms" {
        guard i + 1 < tokens.count, let value = Int(tokens[i + 1]), value > 0 else {
            usageError("invalid --timeout-ms")
        }
        timeoutMs = value
        i += 2
    } else if token.hasPrefix("--") {
        usageError("unknown flag: \(token)")
    } else if arg == nil {
        arg = token
        i += 1
    } else {
        usageError("too many arguments")
    }
}

if commandsWithoutArg.contains(cmd) && arg != nil {
    usageError("\(cmd) takes no argument")
}
if cmd == "setRevealSeconds" && arg == nil {
    usageError("setRevealSeconds requires seconds")
}
if cmd == "toggleApp" && (arg ?? "").isEmpty {
    usageError("toggleApp requires a bundle id")
}
// setHidden with no arg means the empty set.
let sendArg: String? = commandsWithArg.contains(cmd) ? (arg ?? "") : nil

let commandName = Notification.Name("dev.yili.smh.debug.command")
let stateName = Notification.Name("dev.yili.smh.debug.state")
let center = DistributedNotificationCenter.default()
let requestID = UUID().uuidString

// Observe before posting so the reply cannot be missed.
var reply: [String: String]? = nil
let observer = center.addObserver(forName: stateName, object: nil, queue: OperationQueue.main) { note in
    guard let info = note.userInfo else { return }
    guard let echoed = info["id"] as? String, echoed == requestID else { return }
    var fields: [String: String] = [:]
    for (key, value) in info {
        guard let key = key as? String, key != "id" else { continue }
        fields[key] = (value as? String) ?? String(describing: value)
    }
    reply = fields
}

var userInfo: [String: String] = ["id": requestID, "cmd": cmd]
if let sendArg {
    userInfo["arg"] = sendArg
}
center.postNotificationName(commandName, object: nil, userInfo: userInfo, deliverImmediately: true)

let deadline = Date(timeIntervalSinceNow: Double(timeoutMs) / 1000.0)
while reply == nil && Date() < deadline {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
}
center.removeObserver(observer)

guard let result = reply else {
    print("TIMEOUT")
    exit(3)
}
print(result.keys.sorted().map { "\($0)=\(result[$0]!)" }.joined(separator: " "))
