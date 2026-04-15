//
//  NotchWindowController.swift
//  ElevenNotch
//
//  Created by Janusz Polowczyk on 26/03/2026.
//

import Cocoa

class NotchWindowController: NSWindowController {

    private let notchHeight: CGFloat = 200

    var viewModel: NotchViewModel?
    weak var screen: NSScreen?

    var openAfterCreate: Bool = false

    init(window: NSWindow, screen: NSScreen) {
        self.screen = screen
        super.init(window: window)

        var notchSize = screen.notchSize
        let viewModel = NotchViewModel(inset: notchSize == .zero ? 0 : -4)

        self.viewModel = viewModel

        contentViewController = NotchViewController(viewModel)

        if notchSize == .zero {
            notchSize = .init(width: 150, height: 28)
        }

        viewModel.deviceNotchRect = CGRect(
            x: screen.frame.origin.x + (screen.frame.width - notchSize.width) / 2,
            y: screen.frame.origin.y + screen.frame.height - notchSize.height,
            width: notchSize.width,
            height: notchSize.height
        )
        window.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak viewModel] in
            viewModel?.screenRect = screen.frame
            if self.openAfterCreate {
                viewModel?.openNotch(.boot)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    convenience init(screen: NSScreen) {
        let window = NotchWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        self.init(window: window, screen: screen)

        let topRect = CGRect(
            x: screen.frame.origin.x,
            y: screen.frame.origin.y + screen.frame.height - notchHeight,
            width: screen.frame.width,
            height: notchHeight
        )
        window.setFrameOrigin(topRect.origin)
        window.setContentSize(topRect.size)
    }

    deinit {
        destroy()
    }


    func destroy() {
        viewModel?.destroy()
        viewModel = nil
        window?.close()
        contentViewController = nil
        window = nil
    }
}
