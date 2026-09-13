import Foundation

/// The browser UI, embedded as a single self-contained page.
///
/// The HTML/CSS/JS source lives in `Resources/index.html` — a real `.html` file, so editors get
/// proper syntax highlighting — and is embedded into the binary at compile time via the SwiftPM
/// `.embedInCode` resource rule (see `Package.swift`), which generates `PackageResources` as raw
/// bytes baked into the executable. No runtime resource bundle and no external assets: the page
/// must work with nothing but this server reachable, and the executable stays one artifact with
/// no bundle-lookup differences between platforms.
enum WebUI {
    static let indexHTML = String(decoding: PackageResources.index_html, as: UTF8.self)
}
