//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
//===----------------------------------------------------------------------===//

import Foundation
import Logging

public struct EnvLoader {
    public static func load(from directory: URL, export: Bool = true, override: Bool = false, logger: Logger? = nil) -> [String: String] {
        let envURL = directory.appendingPathComponent(".env")
        guard FileManager.default.fileExists(atPath: envURL.path) else { return [:] }

        // Security: warn on permissive permissions
        if let attrs = try? FileManager.default.attributesOfItem(atPath: envURL.path),
           let perm = attrs[.posixPermissions] as? UInt16 {
            let mode = perm & 0o777
            if (mode & 0o044) != 0 {
                logger?.warning("Env file \(envURL.path) is readable by group/other. Consider restricting permissions to 600")
            }
        }

        // Size cap (1 MB)
        if let fileSize = (try? FileManager.default.attributesOfItem(atPath: envURL.path)[.size]) as? NSNumber,
           fileSize.intValue > 1_000_000 {
            logger?.warning("Env file \(envURL.lastPathComponent) is larger than 1MB; ignoring for safety")
            return [:]
        }

        var result: [String: String] = [:]
        guard let text = try? String(contentsOf: envURL, encoding: .utf8) else { return [:] }
        for raw in text.split(whereSeparator: { $0.isNewline }) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
                logger?.warning("Skipping invalid environment variable name: '\(key)'")
                continue
            }
            var val = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                val = String(val.dropFirst().dropLast())
            }
            result[key] = val
        }

        if export {
            for (k, v) in result {
                if override || getenv(k) == nil {
                    setenv(k, v, 1)
                }
            }
        }

        return result
    }
}

