import AppKit
import QuartzCore
import Combine
import SwiftUI

/// Application delegate that manages the menu bar status item and popover.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var checkTimer: Timer?
    private var animationTimer: Timer?
    private var animationAngle: CGFloat = 0
    private var badgeLayer: CALayer?
    private let brewManager = BrewManager()

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        scheduleCheckTimer()

        // Initial check
        Task { await brewManager.checkForUpdates() }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = makeStatusIcon(for: .unknown, badgeAngle: 0)
            button.action = #selector(togglePopover)
            button.target = self
            // Ensure the button is layer-backed so we can add a badge layer.
            button.wantsLayer = true
        }

        // Observe state changes to update the icon
        brewManager.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                // Update base image (no badge) and ensure badge layer reflects state.
                self.statusItem.button?.image = self.makeStatusIcon(for: state, badgeAngle: 0)
                self.updateBadgeLayer(for: state)
                // Only rotate the entire badge for the "checking" state. For
                // "updating" we show an indeterminate ring layer instead.
                let shouldAnimate = state == .checking
                if shouldAnimate {
                    self.startIconAnimation()
                } else {
                    self.stopIconAnimation()
                }
            }
            .store(in: &cancellables)
    }

    private var cancellables: Set<AnyCancellable> = []

    /// Composes a menu bar icon from the base symbol with a colored state badge overlay.
    /// - Parameters:
    ///   - state: The current update state.
    ///   - badgeAngle: Rotation angle in degrees for the badge (used for animation).
    /// - Returns: An `NSImage` suitable for the status item button.
    private func makeStatusIcon(for state: UpdateState, badgeAngle: CGFloat) -> NSImage {
        let size = NSSize(width: 22, height: 22)

        let image = NSImage(size: size, flipped: false) { rect in
            // Draw only the base icon here; badge has its own white background
            // and green circle rendered as separate CALayers so it can appear
            // above the mug and remain visually consistent.

            // Draw base icon tinted with the menu bar label color. The SF Symbol
            // may include optical padding; draw it in a slightly adjusted content
            // rect so the white background appears centered behind the mug.
            if let baseImage = NSImage(systemSymbolName: Constants.Symbols.base, accessibilityDescription: state.statusText) {
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                let base = baseImage.withSymbolConfiguration(config) ?? baseImage
                let tinted = Self.tintedImage(base, color: .labelColor, size: rect.size)

                // Draw the symbol at full size inside the status image so it
                // keeps expected visual weight (avoid shrinking the icon).
                let contentRect = rect
                // Respect the flipped state when drawing into the image closure
                tinted.draw(in: contentRect, from: NSZeroRect, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
            }

            // We only draw the base icon here. A separate CALayer is used for the
            // colored badge to avoid coordinate-flipping issues and to make
            // animation simpler.
            return true
        }

        // Non-template so the colored badge is preserved
        image.isTemplate = false
        return image
    }

    /// Ensure a badge CALayer exists on the status button and update its appearance.
    private func updateBadgeLayer(for state: UpdateState) {
        let badgeSize: CGFloat = 11
        let badgeOutlineWidth: CGFloat = 0.5

        guard let button = statusItem.button else { return }

        // Create badge layer if missing
        if badgeLayer == nil {
            let layer = CALayer()
            // Compact badge size
            layer.bounds = CGRect(x: 0, y: 0, width: badgeSize, height: badgeSize)
            // Do not clip sublayers so the white background stroke is visible
            layer.masksToBounds = false
            layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            layer.zPosition = 1
            button.layer?.addSublayer(layer)
            badgeLayer = layer
        }

        guard let badgeLayer else { return }

        // Position and size
        let btnBounds = button.bounds
        // Fixed pixel offsets from the button center provide consistent placement
        // across flipped/unflipped coordinate systems.
        let center = CGPoint(x: btnBounds.midX, y: btnBounds.midY)
        let x = center.x + badgeLayer.bounds.width / 2 + 1
        let y = center.y + badgeLayer.bounds.height / 2 + 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badgeLayer.position = CGPoint(x: x, y: y)

        // Ensure a white circular background sublayer with gray outline behind the symbol.
        let bgSize = CGSize(width: badgeLayer.bounds.width - badgeOutlineWidth, height: badgeLayer.bounds.height - badgeOutlineWidth)
        let bgShape = CAShapeLayer()
        bgShape.bounds = CGRect(origin: .zero, size: bgSize)
        bgShape.path = CGPath(ellipseIn: bgShape.bounds, transform: nil)
        bgShape.fillColor = NSColor.white.cgColor
        bgShape.strokeColor = NSColor.gray.cgColor
        bgShape.lineWidth = badgeOutlineWidth
        bgShape.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        bgShape.shouldRasterize = false
        bgShape.zPosition = 0

        // Symbol layer (green check or other badge symbol)
        let symbolLayer = CALayer()
        symbolLayer.bounds = CGRect(x: -bgShape.lineWidth * 2.5, y: -bgShape.lineWidth * 2.5, width: max(1, badgeLayer.bounds.width + bgShape.lineWidth * 2.5), height: max(1, badgeLayer.bounds.height + bgShape.lineWidth * 2.5))
        symbolLayer.zPosition = 1

        if let symbol = NSImage(systemSymbolName: state.badgeSymbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: badgeSize, weight: .bold)
            let sym = symbol.withSymbolConfiguration(config) ?? symbol
            let badgeImage = Self.tintedImage(sym, color: state.badgeColor, size: NSSize(width: badgeLayer.bounds.width, height: badgeLayer.bounds.height))
            if let cg = badgeImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                symbolLayer.contents = cg
            }
        }

        // Clear previous sublayers
        badgeLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

        if state == .updating {
            // Indeterminate ring indicating active update
            let ring = CAShapeLayer()
            let ringDiameter = max(bgShape.bounds.width, bgShape.bounds.height)
            ring.bounds = CGRect(x: 0, y: 0, width: ringDiameter, height: ringDiameter)
            ring.position = CGPoint(x: badgeLayer.bounds.midX, y: badgeLayer.bounds.midY)
            let inset: CGFloat = 1.5
            ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: inset, dy: inset), transform: nil)
            ring.fillColor = nil
            ring.strokeColor = state.badgeColor.cgColor
            ring.lineWidth = 2.0
            ring.lineCap = .round
            ring.zPosition = 2

            // Rotation animation for the ring
            let anim = CABasicAnimation(keyPath: "transform.rotation.z")
            anim.fromValue = 0
            anim.toValue = Double.pi * 2
            anim.duration = 1.0
            anim.repeatCount = .infinity
            anim.isRemovedOnCompletion = false

            badgeLayer.addSublayer(bgShape)
            bgShape.position = CGPoint(x: badgeLayer.bounds.midX, y: badgeLayer.bounds.midY)
            badgeLayer.addSublayer(ring)
            ring.add(anim, forKey: "rotate")
        } else {
            // Normal badge: white bg + symbol
            badgeLayer.addSublayer(bgShape)
            bgShape.position = CGPoint(x: badgeLayer.bounds.midX, y: badgeLayer.bounds.midY)
            badgeLayer.addSublayer(symbolLayer)
            symbolLayer.position = CGPoint(x: badgeLayer.bounds.midX, y: badgeLayer.bounds.midY)
            symbolLayer.contentsGravity = .resizeAspect
        }

        badgeLayer.isHidden = state == .unknown
        CATransaction.commit()
    }

    /// Creates a copy of an SF Symbol image tinted with the given color.
    /// - Parameters:
    ///   - image: The source SF Symbol image.
    ///   - color: The color to apply.
    ///   - size: The target size to render at.
    /// - Returns: A new non-template image tinted with the specified color.
    private static func tintedImage(_ image: NSImage, color: NSColor, size: NSSize) -> NSImage {
        let result = NSImage(size: size, flipped: false) { rect in
            // Draw the source image respecting the flipped coordinate system
            image.draw(in: rect, from: NSZeroRect, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        result.isTemplate = false
        return result
    }

    /// Returns a new image that contains `image` rotated by `angle` degrees.
    /// Rotation is performed inside the image's own drawing closure so the
    /// transform does not affect outer drawing state.
    private func rotatedImage(_ image: NSImage, by angle: CGFloat, size: NSSize) -> NSImage {
        let result = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            // Translate to center, rotate, then draw the source image centered
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byDegrees: angle)
            transform.concat()

            let drawRect = NSRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
            image.draw(in: drawRect, from: NSZeroRect, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        result.isTemplate = false
        return result
    }

    // MARK: - Icon Animation

    /// Starts a timer that rotates the badge icon for checking/updating states.
    private func startIconAnimation() {
        animationAngle = 0
        animationTimer = Timer.scheduledTimer(withTimeInterval: Constants.UI.animationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let badgeLayer = self.badgeLayer else { return }
                // Rotate the badge layer using a transform
                let angle = CATransform3DMakeRotation((-self.animationAngle - Constants.UI.animationStep) * CGFloat.pi / 180.0, 0, 0, 1)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                badgeLayer.transform = angle
                CATransaction.commit()

                self.animationAngle -= Constants.UI.animationStep
                if self.animationAngle <= -360 {
                    self.animationAngle = 0
                }
            }
        }
    }

    /// Stops the badge rotation animation.
    private func stopIconAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationAngle = 0
        // Reset any transform applied to the badge layer
        if let badgeLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            badgeLayer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient

        let view = MenuBarView(
            brewManager: brewManager,
            onSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.showSettings()
            },
            onQuit: {
                NSApplication.shared.terminate(nil)
            }
        )
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
    }

    // MARK: - Timer

    private func scheduleCheckTimer() {
        checkTimer?.invalidate()
        let interval = Settings.shared.checkIntervalSeconds
        checkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.brewManager.checkForUpdates()
            }
        }
    }

    // MARK: - Actions

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showSettings() {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)

            // Bring app to front for the settings window
            NSApp.activate(ignoringOtherApps: true)
            
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Constants.UI.settingsWidth, height: Constants.UI.settingsHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        let settingsView = SettingsView(
            onSave: { [weak self] _ in
                self?.scheduleCheckTimer()
            },
            onClose: { [weak window] in
                window?.close()
            }
        )

        window.title = L10n.Settings.title
        window.contentView = NSHostingView(rootView: settingsView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        settingsWindow = window

        // Bring app to front for the settings window
        NSApp.activate(ignoringOtherApps: true)
    }
}
