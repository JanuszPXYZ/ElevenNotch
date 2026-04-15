//
//  EventMonitors.swift
//  ElevenNotch
//
//  Created by Janusz Polowczyk on 27/03/2026.
//

import Cocoa
import Combine

final class EventMonitors {
    static let shared = EventMonitors()

    private var mouseMoveEvent: EventMonitor!
    private var mouseDownEvent: EventMonitor!
    private var commandKeyPressedEvent: EventMonitor!

    let mouseLocation: CurrentValueSubject<NSPoint, Never> = .init(.zero)
    let mouseDown: PassthroughSubject<Void, Never> = .init()
    let commandKeyPress: CurrentValueSubject<Bool, Never> = .init(false)


    private init() {
        mouseMoveEvent = EventMonitor(mask: .mouseMoved, handler: { [weak self] _ in
            guard let self = self else { return }
            let mouseLocation = NSEvent.mouseLocation
            self.mouseLocation.send(mouseLocation)
        })
        mouseMoveEvent.start()

        mouseDownEvent = EventMonitor(mask: .leftMouseDown, handler: { [weak self] _ in
            guard let self = self else { return }
            mouseDown.send()
        })
        mouseDownEvent.start()

        commandKeyPressedEvent = EventMonitor(mask: .flagsChanged, handler: { [weak self] event in
            guard let self = self else { return }

            if event?.modifierFlags.contains(.command) == true {
                commandKeyPress.send(true)
            } else {
                commandKeyPress.send(false)
            }
        })

        commandKeyPressedEvent.start()
    }
}
