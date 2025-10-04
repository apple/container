//
//  PublicStructs.swift
//  container
//
//  Created by Morris Richman on 10/4/25.
//

import Foundation

public struct CommandOutline {
    let type: `Type`
    let flag: String
    let variable: String
    
    public enum `Type` {
        case flag, option
    }
}
