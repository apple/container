//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani
//===----------------------------------------------------------------------===//

import Foundation
#if os(macOS)
import Darwin
#else
import Glibc
#endif

enum LogPrefixFormatter {
    // A set of bright ANSI colors to rotate through
    private static let colors: [String] = [
        "\u{001B}[91m", // bright red
        "\u{001B}[92m", // bright green
        "\u{001B}[93m", // bright yellow
        "\u{001B}[94m", // bright blue
        "\u{001B}[95m", // bright magenta
        "\u{001B}[96m", // bright cyan
        "\u{001B}[36m", // cyan
        "\u{001B}[35m", // magenta
        "\u{001B}[34m", // blue
        "\u{001B}[33m", // yellow
        "\u{001B}[32m", // green
        "\u{001B}[31m"  // red
    ]

    private static let reset = "\u{001B}[0m"

    /// Deterministically map a name to a color index
    private static func colorIndex(for name: String) -> Int {
        var hash: UInt64 = 1469598103934665603 // FNV-1a 64-bit offset
        for b in name.utf8 {
            hash ^= UInt64(b)
            hash &*= 1099511628211
        }
        return Int(hash % UInt64(colors.count))
    }

    /// Return a (optionally colored) prefix like "name | " with width capping/truncation
    static func coloredPrefix(for name: String, width: Int? = nil, colorEnabled: Bool = true) -> String {
        // Respect NO_COLOR and non-TTY outputs
        let disableColor = !colorEnabled || ProcessInfo.processInfo.environment.keys.contains("NO_COLOR") || isatty(STDOUT_FILENO) == 0
        if disableColor {
            let shown = adjust(name, to: width)
            return "\(shown) | "
        }
        let idx = colorIndex(for: name)
        let color = colors[idx]
        let shown = adjust(name, to: width)
        return "\(color)\(shown) | \(reset)"
    }

    /// Truncate to width if longer; otherwise pad to width
    private static func adjust(_ name: String, to width: Int?) -> String {
        guard let w = width else { return name }
        if name.count > w {
            // Truncate tail to fit width
            let endIndex = name.index(name.startIndex, offsetBy: w)
            return String(name[..<endIndex])
        }
        if w > name.count {
            let paddingCount = w - name.count
            return name + String(repeating: " ", count: paddingCount)
        }
        return name
    }
}
