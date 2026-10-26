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

import ContainerizationOCI
import Foundation
import GRPCCore
import Logging

typealias CRIImageAPI = Runtime_V1_ImageService

/// The kubelet's CRI image service. When the kubelet asks for an image that
/// containerd does not have and the host store does, it records the host
/// image in containerd first. Everything else goes to containerd's own CRI
/// image service.
struct ImageService: CRIImageAPI.SimpleServiceProtocol {
    let containerd: any CRIImageAPI.ClientProtocol
    let host: any HostStore
    /// Records a host image in containerd under its normalized reference.
    let recordHostImage: @Sendable (_ reference: String) async throws -> Void
    let log: Logger
    /// How long to wait for containerd's CRI plugin to see a recorded image.
    var imageWait: Duration = .seconds(10)

    func listImages(request: Runtime_V1_ListImagesRequest, context: ServerContext) async throws -> Runtime_V1_ListImagesResponse {
        try await containerd.listImages(request)
    }

    func removeImage(request: Runtime_V1_RemoveImageRequest, context: ServerContext) async throws -> Runtime_V1_RemoveImageResponse {
        try await containerd.removeImage(request)
    }

    func streamImages(
        request: Runtime_V1_StreamImagesRequest,
        response: RPCWriter<Runtime_V1_StreamImagesResponse>,
        context: ServerContext
    ) async throws {
        try await containerd.streamImages(request) { upstream in
            for try await message in upstream.messages {
                try await response.write(message)
            }
        }
    }

    func imageFsInfo(request: Runtime_V1_ImageFsInfoRequest, context: ServerContext) async throws -> Runtime_V1_ImageFsInfoResponse {
        try await containerd.imageFsInfo(request)
    }

    func imageStatus(request: Runtime_V1_ImageStatusRequest, context: ServerContext) async throws -> Runtime_V1_ImageStatusResponse {
        let response = try await containerd.imageStatus(request)
        if response.hasImage {
            return response
        }
        guard try await recordIfOnHost(reference: request.image.image) else {
            return response
        }
        return try await waitForImage(request)
    }

    func pullImage(request: Runtime_V1_PullImageRequest, context: ServerContext) async throws -> Runtime_V1_PullImageResponse {
        guard try await recordIfOnHost(reference: request.image.image) else {
            return try await containerd.pullImage(request)
        }

        var statusRequest = Runtime_V1_ImageStatusRequest()
        statusRequest.image = request.image
        let status = try await waitForImage(statusRequest)
        guard status.hasImage else {
            throw RPCError(code: .internalError, message: "image \(request.image.image) missing after recording it from the host")
        }
        var response = Runtime_V1_PullImageResponse()
        response.imageRef = status.image.id
        return response
    }

    /// Asks containerd for an image's status until it has the image or
    /// `imageWait` passes. containerd's CRI plugin adds a recorded image to
    /// its cache when it handles the image's create event, after the record.
    private func waitForImage(_ request: Runtime_V1_ImageStatusRequest) async throws -> Runtime_V1_ImageStatusResponse {
        let deadline = ContinuousClock.now + imageWait
        while true {
            let response = try await containerd.imageStatus(request)
            if response.hasImage || ContinuousClock.now >= deadline {
                return response
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Records `reference` in containerd when the host store has it, and
    /// reports whether it did. When the host store cannot be reached it logs
    /// the error and reports false, so the request falls through to containerd.
    private func recordIfOnHost(reference: String) async throws -> Bool {
        guard let normalized = normalizedReference(reference) else {
            return false
        }
        do {
            _ = try await host.image(reference: normalized)
        } catch let error as RPCError where error.code == .notFound {
            return false
        } catch {
            log.warning("host store lookup failed", metadata: ["reference": "\(normalized)", "error": "\(error)"])
            return false
        }
        do {
            try await recordHostImage(normalized)
        } catch {
            throw RPCError(code: .internalError, message: "record host image \(normalized): \(error)")
        }
        return true
    }
}

/// Normalizes an image reference the way containerd's CRI plugin does: no
/// domain means docker.io, a single-name docker.io path gets library/, and no
/// tag or digest means latest. Returns nil for a reference that does not parse.
func normalizedReference(_ reference: String) -> String? {
    guard let parsed = try? Reference.parse(reference) else {
        return nil
    }
    let qualified: Reference
    if parsed.domain == nil {
        guard let withDomain = try? Reference.parse("docker.io/\(reference)") else {
            return nil
        }
        qualified = withDomain
    } else {
        qualified = parsed
    }
    qualified.normalize()
    return qualified.description
}
