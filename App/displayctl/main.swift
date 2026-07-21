import Darwin
import Foundation

let wantsJSON = CommandLine.arguments.contains("--json")

// Keep failures machine-readable whenever the caller requested JSON, including
// parser errors that occur before the application can build a response object.
do {
    try DisplayCtlApplication().run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch let error as DisplayCtlError {
    if wantsJSON,
       let data = try? JSONSerialization.data(withJSONObject: ["ok": false, "error": error.description], options: [.sortedKeys]) {
        fputs(String(decoding: data, as: UTF8.self) + "\n", stderr)
    } else {
        fputs("\(L10n.text("Ошибка", "Error")): \(error.description)\n", stderr)
    }
    exit(2)
} catch {
    let details = String(reflecting: error)
    if wantsJSON,
       let data = try? JSONSerialization.data(withJSONObject: ["ok": false, "error": details], options: [.sortedKeys]) {
        fputs(String(decoding: data, as: UTF8.self) + "\n", stderr)
    } else {
        fputs("\(L10n.text("Непредвиденная ошибка", "Unexpected error")): \(details)\n", stderr)
    }
    exit(1)
}
