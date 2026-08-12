import Foundation

/// Resolves where cached responses live, per platform convention.
///
/// This exists as its own type rather than a hardcoded `~/Library/Caches` because the core has to
/// work as a first-class citizen on Windows, not merely compile there.
public enum CacheLocation {
    /// The platform-appropriate cache directory for Swira.
    ///
    /// - Windows: `%LOCALAPPDATA%\Swira\Cache`
    /// - macOS: `~/Library/Caches/Swira`
    /// - Linux and everything else: `$XDG_CACHE_HOME/swira`, falling back to `~/.cache/swira`
    public static func `default`(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        #if os(Windows)
        if let localAppData = environment["LOCALAPPDATA"], !localAppData.isEmpty {
            return URL(fileURLWithPath: localAppData, isDirectory: true)
                .appendingPathComponent("Swira", isDirectory: true)
                .appendingPathComponent("Cache", isDirectory: true)
        }
        #elseif os(macOS)
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            return caches.appendingPathComponent("Swira", isDirectory: true)
        }
        #else
        if let xdg = environment["XDG_CACHE_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("swira", isDirectory: true)
        }
        #endif

        return homeDirectory(environment: environment)
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("swira", isDirectory: true)
    }

    private static func homeDirectory(environment: [String: String]) -> URL {
        #if os(Windows)
        if let profile = environment["USERPROFILE"], !profile.isEmpty {
            return URL(fileURLWithPath: profile, isDirectory: true)
        }
        #endif
        if let home = environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }
}
