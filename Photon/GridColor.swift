//
//  GridColor.swift
//  Photon
//
//  Created by Kevin Ngo on 8/4/26.
//

import SwiftUI

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension Color {
    static let gridCyanBlue = Color(hex: 0x00D9FF)
    static let gridGreen = Color(hex: 0x2ED47A)
    static let gridOrange = Color(hex: 0xFF8C1A)
    static let gridRed = Color(hex: 0xFF3B3B)
    static let boardTileA = Color(hex: 0x2B3550)
    static let boardTileB = Color(hex: 0x3E4B6E)
    static let gridUIBackground = Color(hex: 0x0B0E15)
    static let gridUIElevated = Color(hex: 0x171D29)
    static let gridUIHighlight = Color(hex: 0x232B3B)
    static let textPrimary = Color(hex: 0xEDEFF3)
    static let textSecondary = Color(hex: 0x8B93A3)
    static let textMuted = Color(hex: 0x565D6B)

    /// A player's color: Photon (0) is cyan, Amber (1) orange, shared sources green.
    static func seat(_ owner: Int) -> Color {
        switch owner {
        case 0: .gridCyanBlue
        case 1: .gridOrange
        default: .gridGreen
        }
    }
}
