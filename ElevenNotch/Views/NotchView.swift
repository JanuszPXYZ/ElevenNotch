//
//  NotchView.swift
//  ElevenNotch
//
//  Created by Janusz Polowczyk on 26/03/2026.
//

import SwiftUI
import Combine
internal import UniformTypeIdentifiers


struct NotchView: View {
    @StateObject var viewModel: NotchViewModel

    @State private var dropTargeting: Bool = false

    var notchSize: CGSize {
        switch viewModel.status {
        case .closed:
            var closedSize = CGSize(
                width: viewModel.deviceNotchRect.width - 4,
                height: viewModel.deviceNotchRect.height - 4
            )

            if closedSize.width < 0 { closedSize.width = 0 }
            if closedSize.height < 0 { closedSize.height = 0 }
            return closedSize
        case .opened:
            return viewModel.notchOpenedSize
        case .popping:
            return .init(
                width: viewModel.deviceNotchRect.width,
                height: viewModel.deviceNotchRect.height + 4
            )
        }
    }

    var notchCornerRadius: CGFloat {
        switch viewModel.status {
        case .closed:
            return 8
        case .opened:
            return 32
        case .popping:
            return 10
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            notch
                .zIndex(0)
                .disabled(true)
                .opacity(viewModel.notchVisible ? 1 : 0.3)

            Group {
                if viewModel.status == .opened {
                    VStack(spacing: viewModel.spacing) {
                        NotchHeader()
                            .environmentObject(viewModel)
                        NotchContentView(viewModel: viewModel)
                    }
                    .padding(viewModel.spacing)
                    .frame(maxWidth: viewModel.notchOpenedSize.width, maxHeight: viewModel.notchOpenedSize.height)
                    .zIndex(1)
                }
            }
            .transition(
                .scale.combined(with: .opacity)
                .combined(with: .offset(y: -viewModel.notchOpenedSize.height / 2))
                .animation(viewModel.animation)
            )
        }
        .animation(viewModel.animation, value: viewModel.status)
        .preferredColorScheme(.dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    var notch: some View {
        Rectangle()
            .foregroundStyle(.black)
            .mask(notchBackgroundMaskGroup)
            .frame(width: notchSize.width + notchCornerRadius * 2,
                   height: notchSize.height)
            .shadow(color: .black.opacity(([.opened, .popping].contains(viewModel.status)) ? 0 : 0), radius: 16)
    }

    var notchBackgroundMaskGroup: some View {
        Rectangle()
            .foregroundStyle(.black)
            .frame(width: notchSize.width, height: notchSize.height)
            .clipShape(
                .rect(
                    bottomLeadingRadius: notchCornerRadius,
                    bottomTrailingRadius: notchCornerRadius
                )
            )
            .overlay {
                ZStack(alignment: .topTrailing) {
                    Rectangle()
                        .frame(width: notchCornerRadius, height: notchCornerRadius)
                        .foregroundStyle(.black)
                    Rectangle()
                        .clipShape(.rect(topTrailingRadius: notchCornerRadius))
                        .foregroundStyle(.white)
                        .frame(width: notchCornerRadius + viewModel.spacing, height: notchCornerRadius + viewModel.spacing)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .frame(maxWidth : .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(x: -notchCornerRadius - viewModel.spacing + 0.5, y: -0.5)
            }
            .overlay {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .frame(width: notchCornerRadius, height: notchCornerRadius)
                        .foregroundStyle(.black)
                    Rectangle()
                        .clipShape(.rect(topLeadingRadius: notchCornerRadius))
                        .foregroundStyle(.white)
                        .frame(width: notchCornerRadius + viewModel.spacing, height: notchCornerRadius + viewModel.spacing)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .frame(maxWidth : .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .offset(x: notchCornerRadius + viewModel.spacing - 0.5, y: -0.5)
            }
    }
}
