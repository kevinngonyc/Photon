//
//  DiffuserShape.swift
//  Photon
//
//  Created by Kevin Ngo on 8/5/26.
//

import SwiftUI

struct DiffuserShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()

        let t = min(rect.width, rect.height) * 0.10

        let x = rect.width * 0.5
        let y = rect.height * 0.5

        // Vertical
        p.move(to: CGPoint(x: x, y: 0))
        p.addLine(to: CGPoint(x: x, y: y))

        // Horizontal
        p.move(to: CGPoint(x: x, y: y))
        p.addLine(to: CGPoint(x: rect.width, y: y))

        // Diagonal THROUGH the intersection
        p.move(to: CGPoint(x: 0, y: rect.height))
        p.addLine(to: CGPoint(x: x, y: y))

        return p.strokedPath(
            .init(
                lineWidth: t,
                lineCap: .round,
                lineJoin: .round
            )
        )
    }
}
