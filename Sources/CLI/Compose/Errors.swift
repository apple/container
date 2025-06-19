//
//  Errors.swift
//  Container-Compose
//
//  Created by Morris Richman on 6/18/25.
//

import Foundation

enum YamlError: Error, LocalizedError {
    case dockerfileNotFound(String)
    
    var errorDescription: String? {
        switch self {
        case .dockerfileNotFound(let path):
            return "docker-compose.yml not found at \(path)"
        }
    }
}

enum ComposeError: Error, LocalizedError {
    case imageNotFound(String)
    case invalidProjectName
    
    var errorDescription: String? {
        switch self {
        case .imageNotFound(let name):
            return "Service \(name) must define either 'image' or 'build'."
        case .invalidProjectName:
            return "Could not find project name."
        }
    }
}

enum TerminalError: Error, LocalizedError {
    case commandFailed(String)
    
    var errorDescription: String? {
        return "Command failed: \(self)"
    }
}

/// An enum representing streaming output from either `stdout` or `stderr`.
enum CommandOutput {
    case stdout(String)
    case stderr(String)
    case exitCode(Int32)
}
