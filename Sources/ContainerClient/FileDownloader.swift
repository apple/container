//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

        let client = FileDownloader.createClient()
        _ = try await client.execute(request: request, delegate: delegate).get()
        try await client.shutdown()
    }

    private static func createClient() -> HTTPClient {
        var httpConfiguration = HTTPClient.Configuration()
        let proxyConfig: HTTPClient.Configuration.Proxy? = {
            let proxyEnv = ProcessInfo.processInfo.environment["HTTP_PROXY"]
            guard let proxyEnv else {
                return nil
            }
            guard let url = URL(string: proxyEnv), let host = url.host(), let port = url.port else {
                return nil
            }
            return .server(host: host, port: port)
        }()
        httpConfiguration.proxy = proxyConfig
        return HTTPClient(eventLoopGroupProvider: .singleton, configuration: httpConfiguration)
    }
}
