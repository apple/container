//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors. All rights reserved.
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
import Yams
import ContainerizationError
import Logging

public struct ComposeParser {
    private let log: Logger
    private let merger: ComposeFileMerger
    private let allowAnchors: Bool
    
    public init(log: Logger, allowAnchors: Bool = false) {
        self.log = log
        self.merger = ComposeFileMerger(log: log)
        self.allowAnchors = allowAnchors
    }
    
    /// Parse and merge multiple docker-compose files
    public func parse(from urls: [URL]) throws -> ComposeFile {
        guard !urls.isEmpty else {
            throw ContainerizationError(
                .invalidArgument,
                message: "No compose files specified"
            )
        }

        let projectDirectory = urls[0].deletingLastPathComponent()
        let overrideEnvironment = ProcessInfo.processInfo.environment
        let defaults = try loadDefaultEnvFile(
            from: projectDirectory,
            expansionEnvironment: overrideEnvironment
        )
        let environment = mergedEnvironment(defaults: defaults, overrides: overrideEnvironment)
        let merged = try parseProject(
            from: urls,
            environment: environment,
            overrideEnvironment: overrideEnvironment,
            includeStack: []
        )

        try validate(merged)
        return merged
    }
    
    /// Parse a single docker-compose.yaml file from the given URL
    public func parse(from url: URL) throws -> ComposeFile {
        try parse(from: [url])
    }
    
    /// Parse compose file from data without validation (for internal use)
    private func parseWithoutValidation(from url: URL, environment: [String: String]) throws -> ComposeFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ContainerizationError(
                .notFound,
                message: "Compose file not found at path: \(url.path)"
            )
        }
        
        let data = try Data(contentsOf: url)
        let composeFile = try parseWithoutValidation(from: data, environment: environment)
        return normalizeIncludePaths(in: composeFile, relativeTo: url.deletingLastPathComponent())
    }
    
    /// Parse compose file from data without validation
    private func parseWithoutValidation(from data: Data, environment: [String: String]) throws -> ComposeFile {
        guard let yamlString = String(data: data, encoding: .utf8) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "Unable to decode compose file as UTF-8"
            )
        }

        try validateYamlContent(yamlString)
        
        do {
            // Decode directly without intermediate dump/reload
            let decoder = YAMLDecoder()
            
            // First try to decode directly (no interpolation needed)
            if !yamlString.contains("$") {
                return try decoder.decode(ComposeFile.self, from: data)
            }
            
            let interpolatedYaml = try interpolateYamlString(yamlString, environment: environment)
            let interpolatedData = interpolatedYaml.data(using: .utf8)!
            
            return try decoder.decode(ComposeFile.self, from: interpolatedData)
        } catch let error as DecodingError {
            throw ContainerizationError(
                .invalidArgument,
                message: "Failed to parse compose file: \(describeDecodingError(error))"
            )
        } catch {
            throw error
        }
    }
    
    /// Parse compose file from data
    public func parse(from data: Data) throws -> ComposeFile {
        guard let yamlString = String(data: data, encoding: .utf8) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "Unable to decode compose file as UTF-8"
            )
        }

        // Security: Check for potentially malicious YAML content
        try validateYamlContent(yamlString)

        do {
            // Decode directly without intermediate dump/reload
            let decoder = YAMLDecoder()
            let environment = ProcessInfo.processInfo.environment

            // First try to decode directly (no interpolation needed)
            if !yamlString.contains("$") {
                let composeFile = try decoder.decode(ComposeFile.self, from: data)
                try validateDataBackedParse(composeFile)
                try validateEnvironmentKeysPreflight(composeFile)
                try validate(composeFile)
                return composeFile
            }

            let interpolatedYaml = try interpolateYamlString(yamlString, environment: environment)
            let interpolatedData = interpolatedYaml.data(using: .utf8)!

            let composeFile = try decoder.decode(ComposeFile.self, from: interpolatedData)
            try validateDataBackedParse(composeFile)
            try validateEnvironmentKeysPreflight(composeFile)
            try validate(composeFile)

            return composeFile
        } catch let error as DecodingError {
            throw ContainerizationError(
                .invalidArgument,
                message: "Failed to parse compose file: \(describeDecodingError(error))"
            )
        } catch {
            throw error
        }
    }

    /// Additional safeguard to validate environment keys after decoding
    private func validateEnvironmentKeysPreflight(_ composeFile: ComposeFile) throws {
        for (name, svc) in composeFile.services {
            if let env = svc.environment {
                switch env {
                case .dict(let dict):
                    for (k, _) in dict { try checkEnvName(k, service: name) }
                case .list(let list):
                    for item in list {
                        let key = String(item.split(separator: "=", maxSplits: 1).first ?? "")
                        if !key.isEmpty { try checkEnvName(key, service: name) }
                    }
                }
            }
        }
    }

    private func checkEnvName(_ key: String, service: String) throws {
        let valid = isValidSimpleEnvName(key)
        if !valid {
            throw ContainerizationError(
                .invalidArgument,
                message: "Invalid environment variable name: '\(key)' in service '\(service)'"
            )
        }
    }
    
    private func isValidSimpleEnvName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        func isAlphaOrUnderscore(_ s: Unicode.Scalar) -> Bool {
            return ("A"..."Z").contains(s) || ("a"..."z").contains(s) || s == "_"
        }
        func isAlnumOrUnderscore(_ s: Unicode.Scalar) -> Bool {
            return isAlphaOrUnderscore(s) || ("0"..."9").contains(s)
        }
        guard isAlphaOrUnderscore(first) else { return false }
        for s in name.unicodeScalars.dropFirst() {
            if !isAlnumOrUnderscore(s) { return false }
        }
        return true
    }

    /// Validate YAML content for security issues
    private func validateYamlContent(_ yamlString: String) throws {
        // Check for potentially dangerous YAML constructs using universal patterns
        // Look for any !!tag/ patterns that could be dangerous
        let tagPattern = "!![a-zA-Z][a-zA-Z0-9._-]*"
        if let regex = try? NSRegularExpression(pattern: tagPattern) {
            let matches = regex.matches(in: yamlString, range: NSRange(yamlString.startIndex..., in: yamlString))
            for match in matches {
                if let range = Range(match.range, in: yamlString) {
                    let tag = String(yamlString[range])
                    // Allow safe built-in YAML tags
                    let safeTags = ["!!str", "!!int", "!!float", "!!bool", "!!null", "!!seq", "!!map", "!!binary", "!!timestamp"]
                    if !safeTags.contains(tag) {
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "Potentially unsafe YAML tag detected: \(tag)"
                        )
                    }
                }
            }
        }

        // Check for YAML anchors and merge keys that can cause DoS
        if !allowAnchors {
            if yamlString.contains("&") || yamlString.contains("<<:") {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "YAML anchors and merge keys are not allowed for security reasons (use --allow-anchors to override)"
                )
            }
        }

        // Check file size limit (prevent DoS with extremely large files)
        let maxSize = 9_000_000 // ~9MB limit to catch ~10,000,000 byte strings
        if yamlString.utf8.count > maxSize {
            throw ContainerizationError(
                .invalidArgument,
                message: "Compose file too large (max \(maxSize) bytes)"
            )
        }

        // Check for excessive nesting depth (prevent stack overflow)
        let maxDepth = 20
        var maxFoundDepth = 0
        var currentDepth = 0

        for char in yamlString {
            if char == " " {
                currentDepth += 1
                maxFoundDepth = max(maxFoundDepth, currentDepth)
            } else if char != "\n" && char != "\r" {
                currentDepth = 0
            }

            if maxFoundDepth > maxDepth * 2 { // 2 spaces per indentation level
                throw ContainerizationError(
                    .invalidArgument,
                    message: "YAML nesting depth too deep (max \(maxDepth) levels)"
                )
            }
        }

        // Environment-variable name validation is enforced during decoding and preflight
        // to avoid false positives from textual scanning. Text scanning is disabled here.
    }

    private func validateDataBackedParse(_ composeFile: ComposeFile) throws {
        if composeFile.include != nil {
            throw ContainerizationError(
                .invalidArgument,
                message: "Compose files using 'include' must be parsed from file-backed URLs so relative paths and project directories can be resolved"
            )
        }
    }

    private func parseProject(
        from urls: [URL],
        environment: [String: String],
        overrideEnvironment: [String: String],
        includeStack: [String]
    ) throws -> ComposeFile {
        let projectKey = urls
            .map { $0.standardizedFileURL.path }
            .joined(separator: "|")

        if includeStack.contains(projectKey) {
            throw ContainerizationError(
                .invalidArgument,
                message: "Circular compose include detected involving \(urls.map(\.lastPathComponent).joined(separator: ", "))"
            )
        }

        var composeFiles: [ComposeFile] = []
        for url in urls {
            try validateReadableComposeFile(url)
            let file = try parseWithoutValidation(from: url, environment: environment)
            composeFiles.append(file)
            log.info("Loaded compose file: \(url.lastPathComponent)")
        }

        var merged = merger.merge(composeFiles)
        merged = annotateEnvFileEnvironment(in: merged, environment: environment)
        if urls.count > 1 {
            log.info("Merged \(urls.count) compose files")
        }

        if let includes = merged.include, !includes.isEmpty {
            let nextStack = includeStack + [projectKey]
            for include in includes {
                let included = try loadIncludedCompose(
                    include,
                    parentOverrideEnvironment: overrideEnvironment,
                    includeStack: nextStack
                )
                merged = try mergeIncludedCompose(into: merged, included: included)
            }
        }

        return ComposeFile(
            version: merged.version,
            name: merged.name,
            services: merged.services,
            networks: merged.networks,
            volumes: merged.volumes
        )
    }

    private func loadIncludedCompose(
        _ include: ComposeInclude,
        parentOverrideEnvironment: [String: String],
        includeStack: [String]
    ) throws -> ComposeFile {
        let includeURLs = include.path.asArray.map { URL(fileURLWithPath: $0).standardizedFileURL }
        guard !includeURLs.isEmpty else {
            throw ContainerizationError(
                .invalidArgument,
                message: "Compose include must define at least one path"
            )
        }

        let projectDirectory = resolveIncludeProjectDirectory(include, includeURLs: includeURLs)
        let defaults = try loadIncludedEnvironmentDefaults(
            include,
            parentEnvironment: parentOverrideEnvironment,
            projectDirectory: projectDirectory
        )
        let environment = mergedEnvironment(defaults: defaults, overrides: parentOverrideEnvironment)
        let parsed = try parseProject(
            from: includeURLs,
            environment: environment,
            overrideEnvironment: parentOverrideEnvironment,
            includeStack: includeStack
        )
        return normalizeIncludedCompose(parsed, projectDirectory: projectDirectory)
    }

    private func resolveIncludeProjectDirectory(_ include: ComposeInclude, includeURLs: [URL]) -> URL {
        if let projectDirectory = include.projectDirectory, !projectDirectory.isEmpty {
            return URL(fileURLWithPath: projectDirectory).standardizedFileURL
        }
        return includeURLs[0].deletingLastPathComponent().standardizedFileURL
    }

    private func loadIncludedEnvironmentDefaults(
        _ include: ComposeInclude,
        parentEnvironment: [String: String],
        projectDirectory: URL
    ) throws -> [String: String] {
        if let envFile = include.envFile {
            return try loadEnvFiles(
                urls: envFile.asArray.map { URL(fileURLWithPath: $0).standardizedFileURL },
                expansionEnvironment: parentEnvironment
            )
        }
        return try loadDefaultEnvFile(from: projectDirectory, expansionEnvironment: parentEnvironment)
    }

    private func loadDefaultEnvFile(
        from directory: URL,
        expansionEnvironment: [String: String]
    ) throws -> [String: String] {
        let envURL = directory.appendingPathComponent(".env").standardizedFileURL
        guard FileManager.default.fileExists(atPath: envURL.path) else {
            return [:]
        }
        return try loadEnvFiles(urls: [envURL], expansionEnvironment: expansionEnvironment)
    }

    private func loadEnvFiles(
        urls: [URL],
        expansionEnvironment: [String: String]
    ) throws -> [String: String] {
        var environment: [String: String] = [:]
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ContainerizationError(
                    .notFound,
                    message: "Include env_file not found at path: \(url.path)"
                )
            }
            let mergedExpansionEnvironment = mergedEnvironment(defaults: environment, overrides: expansionEnvironment)
            let loaded = try loadEnvFile(url: url, expansionEnvironment: mergedExpansionEnvironment)
            for (key, value) in loaded {
                environment[key] = value
            }
        }
        return environment
    }

    private func loadEnvFile(
        url: URL,
        expansionEnvironment: [String: String]
    ) throws -> [String: String] {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let perm = attrs[.posixPermissions] as? UInt16 {
            let mode = perm & 0o777
            if (mode & 0o044) != 0 {
                log.warning("Env file \(url.path) is readable by group/other. Consider restricting permissions to 600")
            }
        }

        if let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
           fileSize.intValue > 1_000_000 {
            log.warning("Env file \(url.lastPathComponent) is larger than 1MB; ignoring for safety")
            return [:]
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [String: String] = [:]

        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }

            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard isValidSimpleEnvName(key) else {
                log.warning("Skipping invalid environment variable name: '\(key)'")
                continue
            }

            var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            let isSingleQuoted = value.hasPrefix("'") && value.hasSuffix("'")
            let isDoubleQuoted = value.hasPrefix("\"") && value.hasSuffix("\"")

            if isSingleQuoted || isDoubleQuoted {
                value = String(value.dropFirst().dropLast())
            }

            if !isSingleQuoted {
                value = try ComposeVariableInterpolator.interpolate(value) { variable in
                    if let existingValue = out[variable] {
                        return existingValue
                    }
                    if let expansionValue = expansionEnvironment[variable] {
                        return expansionValue
                    }
                    if let envValue = getenv(variable).flatMap({ String(cString: $0) }) {
                        return envValue
                    }
                    return nil
                }
            }

            out[key] = value
        }

        return out
    }

    private func mergedEnvironment(defaults: [String: String], overrides: [String: String]) -> [String: String] {
        var merged = defaults
        for (key, value) in overrides {
            merged[key] = value
        }
        return merged
    }

    private func validateReadableComposeFile(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ContainerizationError(
                .notFound,
                message: "Compose file not found at path: \(url.path)"
            )
        }
    }

    private func normalizeIncludePaths(in composeFile: ComposeFile, relativeTo baseDirectory: URL) -> ComposeFile {
        guard let includes = composeFile.include else {
            return composeFile
        }

        let normalizedIncludes = includes.map { include in
            ComposeInclude(
                path: normalizeStringOrListPaths(include.path, relativeTo: baseDirectory),
                projectDirectory: include.projectDirectory.map { resolveRelativePath($0, relativeTo: baseDirectory) },
                envFile: include.envFile.map { normalizeStringOrListPaths($0, relativeTo: baseDirectory) }
            )
        }

        return ComposeFile(
            version: composeFile.version,
            name: composeFile.name,
            include: normalizedIncludes,
            services: composeFile.services,
            networks: composeFile.networks,
            volumes: composeFile.volumes
        )
    }

    private func normalizeStringOrListPaths(_ value: StringOrList, relativeTo baseDirectory: URL) -> StringOrList {
        switch value {
        case .string(let raw):
            return .string(resolveRelativePath(raw, relativeTo: baseDirectory))
        case .list(let paths):
            return .list(paths.map { resolveRelativePath($0, relativeTo: baseDirectory) })
        }
    }

    private func resolveRelativePath(_ rawPath: String, relativeTo baseDirectory: URL) -> String {
        let expandedPath = expandHome(in: rawPath)
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath).standardizedFileURL.path
        }
        return baseDirectory.appendingPathComponent(expandedPath).standardizedFileURL.path
    }

    private func expandHome(in path: String) -> String {
        guard path.hasPrefix("~") else {
            return path
        }
        return path.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    private func normalizeIncludedCompose(_ composeFile: ComposeFile, projectDirectory: URL) -> ComposeFile {
        let normalizedServices = composeFile.services.mapValues { service in
            normalizeIncludedService(service, projectDirectory: projectDirectory)
        }

        return ComposeFile(
            version: composeFile.version,
            name: composeFile.name,
            include: composeFile.include,
            services: normalizedServices,
            networks: composeFile.networks,
            volumes: composeFile.volumes
        )
    }

    private func normalizeIncludedService(_ service: ComposeService, projectDirectory: URL) -> ComposeService {
        ComposeService(
            image: service.image,
            build: normalizeIncludedBuildConfig(service.build, projectDirectory: projectDirectory),
            command: service.command,
            entrypoint: service.entrypoint,
            workingDir: service.workingDir,
            environment: service.environment,
            envFile: normalizeIncludedEnvFile(service.envFile, projectDirectory: projectDirectory),
            volumes: normalizeIncludedVolumes(service.volumes, projectDirectory: projectDirectory),
            ports: service.ports,
            networks: service.networks,
            networkMode: service.networkMode,
            dependsOn: service.dependsOn,
            deploy: service.deploy,
            memLimit: service.memLimit,
            cpus: service.cpus,
            containerName: service.containerName,
            healthcheck: service.healthcheck,
            profiles: service.profiles,
            extends: service.extends,
            restart: service.restart,
            labels: service.labels,
            extraHosts: service.extraHosts,
            tty: service.tty,
            stdinOpen: service.stdinOpen,
            envFileEnvironment: service.envFileEnvironment
        )
    }

    private func annotateEnvFileEnvironment(in composeFile: ComposeFile, environment: [String: String]) -> ComposeFile {
        let annotatedServices = composeFile.services.mapValues { service in
            ComposeService(
                image: service.image,
                build: service.build,
                command: service.command,
                entrypoint: service.entrypoint,
                workingDir: service.workingDir,
                environment: service.environment,
                envFile: service.envFile,
                volumes: service.volumes,
                ports: service.ports,
                networks: service.networks,
                networkMode: service.networkMode,
                dependsOn: service.dependsOn,
                deploy: service.deploy,
                memLimit: service.memLimit,
                cpus: service.cpus,
                containerName: service.containerName,
                healthcheck: service.healthcheck,
                profiles: service.profiles,
                extends: service.extends,
                restart: service.restart,
                labels: service.labels,
                extraHosts: service.extraHosts,
                tty: service.tty,
                stdinOpen: service.stdinOpen,
                envFileEnvironment: environment
            )
        }

        return ComposeFile(
            version: composeFile.version,
            name: composeFile.name,
            include: composeFile.include,
            services: annotatedServices,
            networks: composeFile.networks,
            volumes: composeFile.volumes
        )
    }

    private func normalizeIncludedBuildConfig(_ build: BuildConfig?, projectDirectory: URL) -> BuildConfig? {
        guard let build else {
            return nil
        }

        let contextURL = URL(fileURLWithPath: resolveRelativePath(build.context ?? ".", relativeTo: projectDirectory))
        let dockerfile: String? = {
            guard let dockerfile = build.dockerfile, !dockerfile.isEmpty else {
                return build.dockerfile
            }
            if dockerfile.hasPrefix("/") {
                return URL(fileURLWithPath: dockerfile).standardizedFileURL.path
            }
            return contextURL.appendingPathComponent(dockerfile).standardizedFileURL.path
        }()

        return BuildConfig(
            context: contextURL.path,
            dockerfile: dockerfile,
            args: build.args,
            target: build.target
        )
    }

    private func normalizeIncludedEnvFile(_ envFile: StringOrList?, projectDirectory: URL) -> StringOrList? {
        guard let envFile else {
            return nil
        }
        return normalizeStringOrListPaths(envFile, relativeTo: projectDirectory)
    }

    private func normalizeIncludedVolumes(_ volumes: [ServiceVolume]?, projectDirectory: URL) -> [ServiceVolume]? {
        volumes?.map { volume in
            switch volume {
            case .string(let raw):
                return .string(normalizeIncludedShortVolume(raw, projectDirectory: projectDirectory))
            case .object(let object):
                return .object(normalizeIncludedVolumeObject(object, projectDirectory: projectDirectory))
            }
        }
    }

    private func normalizeIncludedShortVolume(_ raw: String, projectDirectory: URL) -> String {
        guard let mount = VolumeMount(from: raw), mount.type == .bind else {
            return raw
        }

        let normalizedSource = resolveRelativePath(mount.source, relativeTo: projectDirectory)
        let components = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard components.count >= 2 else {
            return raw
        }
        if components.count == 3 {
            return "\(normalizedSource):\(components[1]):\(components[2])"
        }
        return "\(normalizedSource):\(components[1])"
    }

    private func normalizeIncludedVolumeObject(_ object: ServiceVolumeObject, projectDirectory: URL) -> ServiceVolumeObject {
        let type = (object.type ?? "bind").lowercased()
        guard type == "bind", let source = object.source, !source.isEmpty else {
            return object
        }

        return ServiceVolumeObject(
            type: object.type,
            source: resolveRelativePath(source, relativeTo: projectDirectory),
            target: object.target,
            readOnly: object.readOnly,
            bind: object.bind,
            tmpfs: object.tmpfs
        )
    }

    private func mergeIncludedCompose(into parent: ComposeFile, included: ComposeFile) throws -> ComposeFile {
        let serviceConflicts = Set(parent.services.keys).intersection(included.services.keys).sorted()
        if !serviceConflicts.isEmpty {
            throw ContainerizationError(
                .invalidArgument,
                message: "Included compose file defines service(s) already defined locally: \(serviceConflicts.joined(separator: ", "))"
            )
        }

        let networkConflicts = Set((parent.networks ?? [:]).keys).intersection(Set((included.networks ?? [:]).keys)).sorted()
        if !networkConflicts.isEmpty {
            throw ContainerizationError(
                .invalidArgument,
                message: "Included compose file defines network(s) already defined locally: \(networkConflicts.joined(separator: ", "))"
            )
        }

        let volumeConflicts = Set((parent.volumes ?? [:]).keys).intersection(Set((included.volumes ?? [:]).keys)).sorted()
        if !volumeConflicts.isEmpty {
            throw ContainerizationError(
                .invalidArgument,
                message: "Included compose file defines volume(s) already defined locally: \(volumeConflicts.joined(separator: ", "))"
            )
        }

        var services = parent.services
        for (name, service) in included.services {
            services[name] = service
        }

        var networks = parent.networks ?? [:]
        for (name, network) in included.networks ?? [:] {
            networks[name] = network
        }

        var volumes = parent.volumes ?? [:]
        for (name, volume) in included.volumes ?? [:] {
            volumes[name] = volume
        }

        return ComposeFile(
            version: parent.version,
            name: parent.name,
            services: services,
            networks: networks.isEmpty ? nil : networks,
            volumes: volumes.isEmpty ? nil : volumes
        )
    }
    
    /// Validate the compose file structure
    private func validate(_ composeFile: ComposeFile) throws {
        // Check version compatibility
        if let version = composeFile.version {
            let supportedVersions = ["2", "2.0", "2.1", "2.2", "2.3", "2.4", 
                                   "3", "3.0", "3.1", "3.2", "3.3", "3.4", "3.5", "3.6", "3.7", "3.8", "3.9"]
            let majorVersion = version.split(separator: ".").first.map(String.init) ?? version
            
            if !supportedVersions.contains(version) && !supportedVersions.contains(majorVersion) {
                log.warning("Compose file version '\(version)' may not be fully supported")
            }
        }
        
        // Validate services
        guard !composeFile.services.isEmpty else {
            throw ContainerizationError(
                .invalidArgument,
                message: "No services defined in compose file"
            )
        }
        
        for (name, service) in composeFile.services {
            try validateService(name: name, service: service)
        }
        
        // Validate circular dependencies
        try validateDependencies(composeFile)
    }
    
    /// Validate individual service configuration
    private func validateService(name: String, service: ComposeService) throws {
        // Either image or build must be specified
        if service.image == nil && service.build == nil {
            throw ContainerizationError(
                .invalidArgument,
                message: "Service '\(name)' must specify either 'image' or 'build'"
            )
        }
        
        // Validate extends configuration
        if let extends = service.extends {
            if extends.service.isEmpty {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "Service '\(name)' extends configuration must specify a service"
                )
            }
        }
        
        // Validate port mappings
        if let ports = service.ports {
            for port in ports {
                if !isValidPortMapping(port) {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "Invalid port mapping '\(port)' in service '\(name)'"
                    )
                }
            }
        }
        
        // Validate environment variable key names when provided as dict/list entries
        if let env = service.environment {
            func isValidName(_ name: String) -> Bool {
                let pattern = "^[A-Za-z_][A-Za-z0-9_]*$"
                let regex = try! NSRegularExpression(pattern: pattern)
                let range = NSRange(name.startIndex..., in: name)
                return regex.firstMatch(in: name, range: range) != nil
            }
            switch env {
            case .dict(let dict):
                for (k, _) in dict {
                    if !isValidName(k) {
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "Invalid environment variable name: '\(k)'"
                        )
                    }
                }
            case .list(let list):
                for item in list {
                    let parts = item.split(separator: "=", maxSplits: 1)
                    if !parts.isEmpty {
                        let key = String(parts[0])
                        if !isValidName(key) {
                            throw ContainerizationError(
                                .invalidArgument,
                                message: "Invalid environment variable name: '\(key)'"
                            )
                        }
                    }
                }
            }
        }
        
        // Validate volume mounts (short-form only)
        if let volumes = service.volumes {
            for v in volumes {
                switch v {
                case .string(let s):
                    if !isValidVolumeMount(s) {
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "Invalid volume mount '\(s)' in service '\(name)'"
                        )
                    }
                case .object:
                    continue
                }
            }
        }
    }
    
    /// Validate dependencies don't have circular references
    private func validateDependencies(_ composeFile: ComposeFile) throws {
        var visited = Set<String>()
        var recursionStack = Set<String>()
        
        func hasCycle(service: String) -> Bool {
            if recursionStack.contains(service) {
                return true
            }
            if visited.contains(service) {
                return false
            }
            
            visited.insert(service)
            recursionStack.insert(service)
            
            if let serviceConfig = composeFile.services[service],
               let dependsOn = serviceConfig.dependsOn {
                for dependency in dependsOn.asList {
                    if hasCycle(service: dependency) {
                        return true
                    }
                }
            }
            
            recursionStack.remove(service)
            return false
        }
        
        for serviceName in composeFile.services.keys {
            if hasCycle(service: serviceName) {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "Circular dependency detected involving service '\(serviceName)'"
                )
            }
        }
    }
    
    /// Check if port mapping is valid
    private func isValidPortMapping(_ port: String) -> Bool {
        // Accept formats:
        // - "8080:80"
        // - "8080:80/tcp"
        // - "127.0.0.1:8080:80"
        // - "127.0.0.1:8080:80/tcp"
        let components = port.split(separator: ":")
        return components.count >= 2 && components.count <= 3
    }
    
    /// Check if volume mount is valid
    private func isValidVolumeMount(_ volume: String) -> Bool {
        // Accept formats:
        // - "container_path" (anonymous volume)
        // - "host_path:container_path"
        // - "host_path:container_path:option" where option in [ro,rw,z,Z,cached,delegated]
        // - "volume_name:container_path[:option]"
        let components = volume.split(separator: ":")
        if components.count == 1 {
            return components[0].hasPrefix("/") // must be an absolute container path
        }
        if components.count < 2 || components.count > 3 {
            return false
        }
        if components.count == 3 {
            let validOptions = ["ro", "rw", "z", "Z", "cached", "delegated"]
            return validOptions.contains(String(components[2]))
        }
        return true
    }
    
    /// Interpolate environment variables directly in YAML string
    private func interpolateYamlString(_ yaml: String, environment: [String: String]) throws -> String {
        try ComposeVariableInterpolator.interpolate(yaml) { environment[$0] }
    }
    
    
    /// Describe decoding error in a user-friendly way
    private func describeDecodingError(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(_, let context):
            return "Type mismatch at \(context.codingPath.map { $0.stringValue }.joined(separator: ".")): \(context.debugDescription)"
        case .valueNotFound(_, let context):
            return "Missing value at \(context.codingPath.map { $0.stringValue }.joined(separator: ".")): \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "Unknown key '\(key.stringValue)' at \(context.codingPath.map { $0.stringValue }.joined(separator: "."))"
        case .dataCorrupted(let context):
            return "Invalid data at \(context.codingPath.map { $0.stringValue }.joined(separator: ".")): \(context.debugDescription)"
        @unknown default:
            return "Unknown parsing error: \(error)"
        }
    }
}
