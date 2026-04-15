//
//  NotchViewController.swift
//  ElevenNotch
//
//  Created by Janusz Polowczyk on 26/03/2026.
//

import AppKit
import Cocoa
import SwiftUI

final class NotchViewController: NSHostingController<NotchView> {
    init(_ viewModel: NotchViewModel) {
        super.init(rootView: .init(viewModel: viewModel))
    }
    
    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
