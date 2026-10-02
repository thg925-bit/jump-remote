import AppKit

/// Reports the Mac cursor's position and shape so the client can draw it itself: a cursor
/// baked into the video only moves at the video's frame rate and latency.
/// Runs on the main thread; callbacks fire there.
final class CursorTracker {
    /// Position normalized over the captured display.
    var onPosition: ((CGPoint) -> Void)?
    /// `{"t":"cursorImage","png":base64 (2x),"w","h","hx","hy"}` in points.
    var onImage: (([String: Any]) -> Void)?

    private var timer: Timer?
    private var displayID: CGDirectDisplayID = CGMainDisplayID()
    private var lastPosition: CGPoint?
    private var lastImageHash: Int?
    private var lastQuickHash: Int?
    private var ticks = 0

    func start(displayID: CGDirectDisplayID) {
        DispatchQueue.main.async {
            self.displayID = displayID
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.poll() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            self.poll()
        }
    }

    /// Follow another display (the client switched monitors).
    func setDisplay(_ displayID: CGDirectDisplayID) {
        DispatchQueue.main.async {
            self.displayID = displayID
            self.lastPosition = nil
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.timer?.invalidate()
            self.timer = nil
        }
    }

    private func poll() {
        if let location = CGEvent(source: nil)?.location {
            let bounds = CGDisplayBounds(displayID)
            let position = CGPoint(x: (location.x - bounds.minX) / bounds.width,
                                   y: (location.y - bounds.minY) / bounds.height)
            if position != lastPosition {
                lastPosition = position
                onPosition?(position)
            }
        }
        ticks += 1
        if ticks % 6 == 1 { checkShape() } // 10 Hz is plenty for shape changes
    }

    private func checkShape() {
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        let size = image.size
        // Cheap test first (the cursor's own bitmap bytes): rendering and PNG-encoding on the
        // main thread ten times a second is only worth it when the shape actually changed.
        var quick = Hasher()
        quick.combine(size.width)
        quick.combine(size.height)
        quick.combine(cursor.hotSpot.x)
        quick.combine(cursor.hotSpot.y)
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let bytes = cg.dataProvider?.data as Data? {
            quick.combine(cg.width)
            quick.combine(bytes)
            let key = quick.finalize()
            if key == lastQuickHash { return }
            lastQuickHash = key
        }
        guard size.width > 0, size.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                            pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }

        var hasher = Hasher()
        png.withUnsafeBytes { hasher.combine(bytes: $0) }
        hasher.combine(cursor.hotSpot.x)
        hasher.combine(cursor.hotSpot.y)
        let hash = hasher.finalize()
        guard hash != lastImageHash else { return }
        lastImageHash = hash

        onImage?([
            "t": "cursorImage",
            "png": png.base64EncodedString(),
            "w": size.width, "h": size.height,
            "hx": cursor.hotSpot.x, "hy": cursor.hotSpot.y,
        ])
    }
}
