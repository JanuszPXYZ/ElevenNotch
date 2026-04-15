//
//  NotchHeader.swift
//  ElevenNotch
//
//  Created by Janusz Polowczyk on 26/03/2026.
//

import SwiftUI

struct NotchHeader: View {
    @EnvironmentObject var viewModel: NotchViewModel

    var body: some View {
        HStack(spacing: 8) {
            Text(viewModel.contentType == .settings ? "API Keys" : "IINotch")
            .foregroundStyle(.white.opacity(0.9))
            Spacer()
            Button(action: viewModel.toggleSettings) {
                Image(systemName: viewModel.contentType == .settings ? "xmark" : "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .animation(viewModel.animation, value: viewModel.contentType)
        .font(.system(size: 15, weight: .semibold))
    }
}
