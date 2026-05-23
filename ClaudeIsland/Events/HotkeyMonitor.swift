//
//  HotkeyMonitor.swift
//  ClaudeIsland
//
//  Detects double-tap of Command key to toggle the dynamic island
//

import AppKit

class HotkeyMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastCommandReleaseTime: TimeInterval = 0
    private var commandWasAlone = true

    /// Called when double-tap Command is detected
    var onDoubleTap: (() -> Void)?

    /// Maximum interval between two Command releases to count as double-tap
    private let doubleTapInterval: TimeInterval = 0.3

    init() {}

    func start() {
        // Global monitor: captures events when other apps are focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        // Local monitor: captures events when our app is focused
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command) {
            // Command pressed - start tracking
            // If other modifiers are held, this isn't a solo Command tap
            let otherModifiers: NSEvent.ModifierFlags = [.shift, .option, .control]
            commandWasAlone = flags.intersection(otherModifiers).isEmpty
        } else if commandWasAlone {
            // Command released and no other modifiers were involved
            let now = Date().timeIntervalSince1970
            let elapsed = now - lastCommandReleaseTime

            if elapsed < doubleTapInterval && elapsed > 0.05 {
                // Double-tap detected
                lastCommandReleaseTime = 0
                DispatchQueue.main.async { [weak self] in
                    self?.onDoubleTap?()
                }
            } else {
                lastCommandReleaseTime = now
            }
        } else {
            // Command released but wasn't alone - reset
            commandWasAlone = true
            lastCommandReleaseTime = 0
        }
    }

    deinit {
        stop()
    }
}

