//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerAPIClient
import ContainerPersistence
import ContainerizationError
import ContainerizationOCI
import Logging

extension K8sHelper {
    // MARK: - Image management

    public static func ensureImage(nodeImage: String = K8sHelper.nodeImage, log: Logger, containerSystemConfig: ContainerSystemConfig) async throws {
        do {
            _ = try await ClientImage.get(reference: nodeImage, containerSystemConfig: containerSystemConfig)
            log.debug("k8s node image present", metadata: ["ref": "\(nodeImage)"])
            return
        } catch let error as ContainerizationError where error.code == .notFound {
            log.info("Pulling k8s node image", metadata: ["ref": "\(nodeImage)"])
        } catch {
            log.error("Failed to check k8s node image status", metadata: ["ref": "\(nodeImage)", "error": "\(error)"])
            throw error
        }
        
        do {
            let platform = try Platform(from: "linux/\(Arch.hostArchitecture().rawValue)")
            _ = try await ClientImage.fetch(
                reference: nodeImage,
                platform: platform,
                containerSystemConfig: containerSystemConfig,
                progressUpdate: nil)
        } catch {
            log.error("Failed to fetch k8s node image", metadata: ["ref": "\(nodeImage)", "error": "\(error)"])
            throw error
        }
    }

    // MARK: - Image reference helpers

    static func isShortName(_ reference: String, log: Logger? = nil) -> Bool {
        do {
            let ref = try Reference.parse(reference)
            return ref.domain == nil
        } catch {
            log?.warning("Failed to parse image reference, treating as short name", metadata: ["ref": "\(reference)", "error": "\(error)"])
            return true
        }
    }

    static func fqReference(_ reference: String, log: Logger? = nil) -> String {
        do {
            var ref = try Reference.parse(reference)
            ref.normalize()
            return ref.description
        } catch {
            log?.error("Failed to parse/normalize fully-qualified image reference, falling back to original string", metadata: ["ref": "\(reference)", "error": "\(error)"])
            return reference
        }
    }
}
