import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Turns input-channel messages (see PROTOCOL.md) into synthetic CGEvents.
///
/// Everything runs in order on one serial queue. Messages arrive on WebRTC's network thread, and a
/// paste (pasteboard, then ⌘V) must never be overtaken by keys typed right after it.
final class InputInjector {
    private let queue = DispatchQueue(label: "jump.input", qos: .userInteractive)
    private var displayID: CGDirectDisplayID = CGMainDisplayID()

    private let source: CGEventSource?
    private var buttonsDown = Set<Int>()
    private var keysDown = Set<CGKeyCode>()
    /// Modifier state from the modifier keys held, with the left/right device bits a real keyboard
    /// sends (both Shifts held and one released still leaves Shift down).
    private var modifierFlags: CGEventFlags {
        var raw: UInt64 = 0
        for key in keysDown {
            if let flag = KeyMap.modifierFlag(for: key) { raw |= flag.rawValue | KeyMap.deviceFlag(for: key) }
        }
        return CGEventFlags(rawValue: raw)
    }
    private var lastPoint: CGPoint = .zero
    private var lastClick: (time: TimeInterval, button: Int, point: CGPoint, count: Int)?
    private var scrollRemainder: CGPoint = .zero
    /// The user's own clipboard while a paste's restore is pending, so pastes in quick
    /// succession put back what was there before the first one, not the previous paste.
    private var pasteSaved: [NSPasteboardItem]?
    private var pasteChangeCount = 0
    private var pasteGeneration = 0

    init() {
        source = CGEventSource(stateID: .hidSystemState)
        // Don't mute the Mac's own mouse/keyboard after each synthetic event.
        source?.localEventsSuppressionInterval = 0
    }

    /// Input coordinates map onto this display from now on.
    func setDisplay(_ id: CGDirectDisplayID) {
        queue.async { self.displayID = id }
    }

    /// Queues one input message.
    func handle(_ message: [String: Any]) {
        queue.async {
            SystemAwake.noteUserActivity()
            self.process(message)
        }
    }

    /// Runs `work` in order with the input (e.g. the client's clipboard ahead of its ⌘V).
    func enqueue(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    private func process(_ message: [String: Any]) {
        switch message["t"] as? String {
        case "move":
            move(to: point(from: message))
        case "down":
            button(message, down: true)
        case "up":
            button(message, down: false)
        case "scroll":
            scroll(dx: number(message["dx"]), dy: number(message["dy"]))
        case "key":
            // 한/영 (HID LANG1) of a PC keyboard: macOS has no use for that key, so switch the
            // input source directly.
            if Int(number(message["code"])) == KeyMap.hangulKey {
                if (message["down"] as? Bool) ?? true { InputSource.toggleKorean() }
                return
            }
            key(message)
        case "text":
            // "paste": the viewer's compose box, where line breaks are text, not Return presses.
            if let text = message["s"] as? String, !text.isEmpty { type(text, paste: message["paste"] as? Bool ?? false) }
        default:
            break
        }
    }

    /// Lifts every held button and key so nothing stays stuck after a disconnect. Waits for
    /// the input still queued.
    func releaseAll() {
        queue.sync { releaseHeld() }
    }

    private func releaseHeld() {
        for button in buttonsDown {
            post(mouse: mouseType(button: button, down: false), button: button, at: lastPoint)
        }
        buttonsDown.removeAll()
        for key in keysDown where KeyMap.modifierFlag(for: key) == nil {
            postKey(key, down: false)
        }
        for key in keysDown where KeyMap.modifierFlag(for: key) != nil {
            keysDown.remove(key)
            postModifier(key)
        }
        keysDown.removeAll()
    }

    // MARK: Mouse

    private func move(to point: CGPoint) {
        let delta = CGPoint(x: point.x - lastPoint.x, y: point.y - lastPoint.y)
        lastPoint = point
        let type: CGEventType
        let button: Int
        if buttonsDown.contains(0) {
            type = .leftMouseDragged; button = 0
        } else if buttonsDown.contains(1) {
            type = .rightMouseDragged; button = 1
        } else if let other = buttonsDown.first {
            type = .otherMouseDragged; button = other
        } else {
            type = .mouseMoved; button = 0
        }
        post(mouse: type, button: button, at: point, delta: delta)
    }

    private func button(_ message: [String: Any], down: Bool) {
        let button = Int(number(message["b"]))
        let point = message["x"] != nil ? point(from: message) : lastPoint
        lastPoint = point

        var clickCount = 1
        let now = ProcessInfo.processInfo.systemUptime
        if down, let forced = message["c"] as? NSNumber {
            // Client knows better (e.g. trackpad-mode drag right after a tap).
            clickCount = max(1, forced.intValue)
            lastClick = (now, button, point, clickCount)
            buttonsDown.insert(button)
        } else if down {
            if let last = lastClick, last.button == button,
               now - last.time < NSEvent.doubleClickInterval,
               hypot(last.point.x - point.x, last.point.y - point.y) < 6 {
                clickCount = min(last.count + 1, 3)
            }
            lastClick = (now, button, point, clickCount)
            buttonsDown.insert(button)
        } else {
            clickCount = lastClick?.count ?? 1
            buttonsDown.remove(button)
        }
        post(mouse: mouseType(button: button, down: down), button: button, at: point, clickCount: clickCount)
    }

    private func scroll(dx: Double, dy: Double) {
        let totalX = scrollRemainder.x + dx
        let totalY = scrollRemainder.y + dy
        let stepX = Int32(totalX.rounded(.towardZero))
        let stepY = Int32(totalY.rounded(.towardZero))
        scrollRemainder = CGPoint(x: totalX - Double(stepX), y: totalY - Double(stepY))
        guard stepX != 0 || stepY != 0,
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: stepY, wheel2: stepX, wheel3: 0)
        else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.flags = modifierFlags
        event.post(tap: .cghidEventTap)
    }

    private func mouseType(button: Int, down: Bool) -> CGEventType {
        switch button {
        case 0: return down ? .leftMouseDown : .leftMouseUp
        case 1: return down ? .rightMouseDown : .rightMouseUp
        default: return down ? .otherMouseDown : .otherMouseUp
        }
    }

    /// `delta`: how far the pointer moved, as a real mouse reports it (the Dock and some apps read it).
    private func post(mouse type: CGEventType, button: Int, at point: CGPoint, clickCount: Int = 1, delta: CGPoint = .zero) {
        let cgButton = CGMouseButton(rawValue: UInt32(max(0, button))) ?? .left
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: cgButton)
        else { return }
        if type != .mouseMoved {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
        event.flags = modifierFlags
        event.post(tap: .cghidEventTap)
    }

    private func point(from message: [String: Any]) -> CGPoint {
        let bounds = CGDisplayBounds(displayID)
        let x = min(max(number(message["x"]), 0), 1)
        let y = min(max(number(message["y"]), 0), 1)
        return CGPoint(x: bounds.minX + x * (bounds.width - 1), y: bounds.minY + y * (bounds.height - 1))
    }

    // MARK: Keyboard

    private func key(_ message: [String: Any]) {
        guard let key = KeyMap.virtualKey(forHIDUsage: Int(number(message["code"]))) else { return }
        let down = (message["down"] as? Bool) ?? true

        if KeyMap.modifierFlag(for: key) != nil {
            if down { keysDown.insert(key) } else { keysDown.remove(key) }
            postModifier(key)
            return
        }

        if down { keysDown.insert(key) } else { keysDown.remove(key) }
        postKey(key, down: down)
    }

    private func postKey(_ key: CGKeyCode, down: Bool, flags: CGEventFlags? = nil) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
        event.flags = (flags ?? modifierFlags).union(KeyMap.implicitFlags(for: key))
        event.post(tap: .cghidEventTap)
    }

    /// Modifier presses are flagsChanged events carrying the new modifier state.
    private func postModifier(_ key: CGKeyCode) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true) else { return }
        event.type = .flagsChanged
        event.flags = modifierFlags
        event.post(tap: .cghidEventTap)
    }

    // MARK: Text

    private func type(_ text: String, paste forcePaste: Bool = false) {
        let plainASCII = text.unicodeScalars.allSatisfy { $0.isASCII && ($0.value >= 0x20 || $0 == "\n") }
        if plainASCII && text.count <= 64 && !forcePaste {
            for character in text {
                if character == "\n" {
                    postKey(CGKeyCode(kVK_Return), down: true, flags: [])
                    postKey(CGKeyCode(kVK_Return), down: false, flags: [])
                } else {
                    postUnicode(String(character))
                }
            }
        } else {
            // Unicode key events fight with the Korean IME; pasting is reliable for any script.
            paste(text)
        }
    }

    private func postUnicode(_ string: String) {
        let utf16 = Array(string.utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            event.flags = []
            utf16.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            event.post(tap: .cghidEventTap)
        }
    }

    /// Puts `text` on the pasteboard, presses ⌘V, and half a second later puts back what the
    /// user had there (unless something else was copied meanwhile).
    private func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        if pasteSaved == nil || pasteboard.changeCount != pasteChangeCount {
            pasteSaved = (pasteboard.pasteboardItems ?? []).map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) { copy.setData(data, forType: type) }
                }
                return copy
            }
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteChangeCount = pasteboard.changeCount
        ClipboardSync.noteOwnChange(pasteChangeCount) // typing, not copying: don't mirror it to the client

        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }

        pasteGeneration += 1
        let generation = pasteGeneration
        queue.asyncAfter(deadline: .now() + 0.5) {
            guard generation == self.pasteGeneration else { return } // a newer paste restores later
            let saved = self.pasteSaved
            self.pasteSaved = nil
            guard pasteboard.changeCount == self.pasteChangeCount else { return }
            pasteboard.clearContents()
            if let saved, !saved.isEmpty { pasteboard.writeObjects(saved) }
            ClipboardSync.noteOwnChange(pasteboard.changeCount)
        }
    }

    private func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }
}
