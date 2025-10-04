//
//  HelperMacrosMacros.swift
//  container
//
//  Created by Morris Richman on 10/3/25.
//

import SwiftCompilerPlugin
import SwiftSyntaxMacros
import SwiftDiagnostics

@main
struct SwiftMacrosAndMePlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        OptionGroupPassthrough.self
    ]
}

extension String: @retroactive Error {
}

enum MacroExpansionError: Error {
    case unsupportedDeclaration
    
    var localizedDescription: String {
        switch self {
        case .unsupportedDeclaration:
            return "Unsupported declaration for macro expansion."
        }
    }
}
