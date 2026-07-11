//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
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

import AsyncHTTPClient
import ContainerizationError
import ContainerizationExtras
import Foundation
import TerminalProgress

public struct FileDownloader {
    public static func downloadFile(url: URL, to destination: URL, progressUpdate: ProgressUpdateHandler? = nil) async throws {
        let request = try HTTPClient.Request(url: url)

        let delegate = try FileDownloadDelegate(
            path: destination.path(),
            reportHead: {
                let expectedSizeString = $0.headers["Content-Length"].first ?? ""
                if let expectedSize = Int64(expectedSizeString) {
                    if let progressUpdate {
                        Task {
                            await progressUpdate([
                                .addTotalSize(expectedSize)
                            ])
                        }
                    }
                }
            },
            reportProgress: {
                let receivedBytes = Int64($0.receivedBytes)
                if let progressUpdate {
                    Task {
                        await progressUpdate([
                            .setSize(receivedBytes)
                        ])
                    }
                }
            })

        let client = FileDownloader.createClient(url: url)
        do {
            _ = try await client.execute(request: request, delegate: delegate).get()
        } catch {
            try? await client.shutdown()
            throw error
        }
        try await client.shutdown()
    }

    private static func createClient(url: URL) -> HTTPClient {
        var httpConfiguration = HTTPClient.Configuration()
        // for large file downloads we keep a generous connect timeout, and
        // no read timeout since download durations can vary
        httpConfiguration.timeout = HTTPClient.Configuration.Timeout(
            connect: .seconds(30),
            read: .none
        )
        if let host = url.host {
            let proxyURL = ProxyUtils.proxyFromEnvironment(scheme: url.scheme, host: host)
            if let proxyURL, let proxyHost = proxyURL.host {
                httpConfiguration.proxy = HTTPClient.Configuration.Proxy.server(host: proxyHost, port: proxyURL.port ?? 8080)
            }
        }

        return HTTPClient(eventLoopGroupProvider: .singleton, configuration: httpConfiguration)
    }
}
