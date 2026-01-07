//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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
import NIOCore
import NIOPosix

extension DNSServer {
    /// Handles the DNS request.
    /// - Parameters:
    ///   - outbound: The NIOAsyncChannelOutboundWriter for which to respond.
    ///   - packet: The request packet.
    func handle(
        outbound: NIOAsyncChannelOutboundWriter<AddressedEnvelope<ByteBuffer>>,
        packet: inout AddressedEnvelope<ByteBuffer>
    ) async throws {
        let chunkSize = 512
        var data = Data()

        self.log?.debug("reading data")
        while packet.data.readableBytes > 0 {
            if let chunk = packet.data.readBytes(length: min(chunkSize, packet.data.readableBytes)) {
                data.append(contentsOf: chunk)
            }
        }

        self.log?.debug("deserializing message")
        let query = try Message(deserialize: data)
        self.log?.debug("processing query: \(query.questions)")

        // always send response
        let responseData: Data
        do {
            self.log?.debug("awaiting processing")
            var response =
                try await handler.answer(query: query)
                ?? Message(
                    id: query.id,
                    type: .response,
                    returnCode: .notImplemented,
                    questions: query.questions,
                    answers: []
                )

            // Only set NXDOMAIN if handler didn't explicitly set noError (NODATA response).
            // This preserves NODATA responses for AAAA queries when A record exists,
            // which prevents musl libc from treating empty AAAA as "domain doesn't exist".
            if response.answers.isEmpty && response.returnCode != .noError {
                response.returnCode = .nonExistentDomain
            }

            self.log?.debug("serializing response")
            responseData = try response.serialize()
        } catch {
            self.log?.error("error processing message from \(query): \(error)")
            let response = Message(
                id: query.id,
                type: .response,
                returnCode: .notImplemented,
                questions: query.questions,
                answers: []
            )
            responseData = try response.serialize()
        }

        self.log?.debug("sending response for \(query.id)")
        let rData = ByteBuffer(bytes: responseData)
        try? await outbound.write(AddressedEnvelope(remoteAddress: packet.remoteAddress, data: rData))

        self.log?.debug("processing done")

    }
}
