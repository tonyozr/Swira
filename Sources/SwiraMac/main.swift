#if canImport(AppKit)
import AppKit

// `main.swift` is the designated entry point for a SwiftPM executable. Top-level expressions
// are legal here; everywhere else they are not.
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
#else
import Foundation
// SwiraMac is macOS-only. Provide a graceful exit on other platforms so the binary still links.
print("SwiraMac requires macOS. Use swira-web or another client on this platform.", to: &standardError)
exit(1)

var standardError = FileHandleOutputStream(FileHandle.standardError)

struct FileHandleOutputStream: TextOutputStream {
    private let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    mutating func write(_ string: String) {
        if let data = string.data(using: .utf8) { handle.write(data) }
    }
}
#endif
