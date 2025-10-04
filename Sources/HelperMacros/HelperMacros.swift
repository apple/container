//
//  HelperMacros.swift
//  container
//
//  Created by Morris Richman on 10/3/25.
//

import Foundation

@attached(member, names: arbitrary)
public macro OptionGroupPassthrough() = #externalMacro(module: "HelperMacrosMacros", type: "OptionGroupPassthrough")
