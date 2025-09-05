//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation

/// A small utility to resolve proxy settings (HTTP(S)_PROXY / NO_PROXY).
public enum ProxyUtils {
    /// Resolves the proxy URL for a given host based on environment variables.
    ///
    /// - Parameters:
    ///   - host: The target hostname (without scheme).
    ///   - env: Optional environment dictionary; defaults to process environment.
    /// - Returns: The proxy URL to use, or `nil` for direct connection.
    public static func proxy(for host: String, env: [String: String]? = nil) -> URL? {
        let env = env ?? ProcessInfo.processInfo.environment
        
        // Case-insensitive lookup for both upper/lower keys
        let httpProxy = env["HTTP_PROXY"] ?? env["http_proxy"]
        let httpsProxy = env["HTTPS_PROXY"] ?? env["https_proxy"]

        let noProxy = env["NO_PROXY"] ?? env["no_proxy"]

        // If NO_PROXY matches → skip proxy
        if let noProxy, shouldBypassProxy(host: host, noProxy: noProxy) {
            return nil
        }

        // Prefer HTTPS proxy if set, otherwise fall back to HTTP proxy
        let proxyStr = httpsProxy ?? httpProxy
        guard let proxyStr, let url = URL(string: proxyStr) else {
            return nil
        }
        return url
    }

    /// Check if a host should bypass proxy according to NO_PROXY.
    /// - Example: NO_PROXY=".example.com,localhost,127.0.0.1"
    private static func shouldBypassProxy(host: String, noProxy: String) -> Bool {
        let entries = noProxy.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for entry in entries {
            if entry.isEmpty { continue }
            if entry == "*" { return true }
            if host == entry { return true }
            if entry.hasPrefix(".") && host.hasSuffix(entry) { return true }
        }
        return false
    }
}
