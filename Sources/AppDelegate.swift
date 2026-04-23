import AppKit
import QuartzCore
import Combine
import Network
import SwiftUI

/// Application delegate that manages the menu bar status item and popover.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private enum DockIconMode {
        case `default`
        case updatesAvailable
    }

    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var checkTimer: Timer?
    private var badgeLayer: CALayer?
    /// Cached sublayers for the static badge (white bg + symbol). Recreated only when
    /// switching between ring mode and static-badge mode.
    private var badgeBgShape: CAShapeLayer?
    private var badgeSymbolLayer: CALayer?
    /// Cached ring sublayer for the indeterminate-progress badge.
    private var badgeRingLayer: CAShapeLayer?
    private let brewManager = BrewManager()
    private var pathMonitor: NWPathMonitor?
    private var defaultDockIcon: NSImage?
    private var updatesAvailableDockIcon: NSImage?
    /// Current Dock icon presentation mode.
    private var dockIconMode: DockIconMode = .default
    /// True after `.updating` until `.updateComplete`, used to ignore stale `.upToDate`.
    private var isUpdateCycleActive = false
    private var currentMugFillLevel: CGFloat = 0.9
    private var mugFillAnimationTimer: Timer?
    private var mugFillAnimationStartLevel: CGFloat = 0.9
    private var mugFillAnimationTargetLevel: CGFloat = 0.9
    private var mugFillAnimationStartTime = Date()
    private var mugFillAnimationDuration: TimeInterval = 0.35
    private var mugFillAnimationState: UpdateState = .unknown

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupDockIcons()
        setupStatusItem()
        setupPopover()
        scheduleCheckTimer()
        checkForUpdatesWhenNetworkReady()
    }

    // MARK: - Network-Aware Initial Check

    /// Runs the first update check as soon as network connectivity is available.
    ///
    /// If a network path is already satisfied at launch (typical for a manual
    /// start), the check fires immediately. If no path is available yet (common
    /// when the app is launched automatically at login before the network stack
    /// is ready), the monitor waits for the first satisfying path event before
    /// triggering the check — and then cancels itself so it never fires again.
    private func checkForUpdatesWhenNetworkReady() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            // Cancel the monitor before dispatching — we only need one trigger.
            monitor.cancel()
            Task { @MainActor [weak self] in
                self?.pathMonitor = nil
                await self?.brewManager.checkForUpdates()
            }
        }
        monitor.start(queue: DispatchQueue(label: "de.devk.koebes.networkMonitor"))
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        currentMugFillLevel = targetMugFillLevel()

        if let button = statusItem.button {
            button.image = makeStatusIcon(for: .unknown, badgeAngle: 0, mugFillLevel: currentMugFillLevel)
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
                // First update centralized icon mode, then render dependent UI.
                self.updateDockIcon(for: state)
                self.animateMugFillTransition(for: state)
                self.updateBadgeLayer(for: state)
            }
            .store(in: &cancellables)
    }

    private var cancellables: Set<AnyCancellable> = []

    /// Composes a menu bar icon from the base symbol with a colored state badge overlay.
    /// - Parameters:
    ///   - state: The current update state.
    ///   - badgeAngle: Rotation angle in degrees for the badge (used for animation).
    /// - Returns: An `NSImage` suitable for the status item button.
    private func makeStatusIcon(for state: UpdateState, badgeAngle: CGFloat, mugFillLevel: CGFloat) -> NSImage {
        let size = NSSize(width: 22, height: 22)

        let image = NSImage(size: size, flipped: false) { rect in
            // Draw only the base icon here; badge has its own white background
            // and green circle rendered as separate CALayers so it can appear
            // above the mug and remain visually consistent.

            // Draw base icon tinted with the menu bar label color. The SF Symbol
            // may include optical padding; draw it in a slightly adjusted content
            // rect so the white background appears centered behind the mug.
            if let baseImage = NSImage(systemSymbolName: Constants.Symbols.baseUpdatesAvailable, accessibilityDescription: state.statusText) {
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                let base = baseImage.withSymbolConfiguration(config) ?? baseImage
                let tinted = Self.tintedImage(base, color: .labelColor, size: rect.size)

                // Draw the symbol at full size inside the status image so it
                // keeps expected visual weight (avoid shrinking the icon).
                let contentRect = rect
                // Respect the flipped state when drawing into the image closure
                tinted.draw(in: contentRect, from: NSZeroRect, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
                Self.drawBeerFill(in: contentRect, level: mugFillLevel)
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

    private func targetMugFillLevel() -> CGFloat {
        switch dockIconMode {
        case .updatesAvailable:
            return 0.2
        case .default:
            return 1.0
        }
    }

    private func animateMugFillTransition(for state: UpdateState) {
        let targetLevel = targetMugFillLevel()
        mugFillAnimationTimer?.invalidate()

        let startLevel = currentMugFillLevel
        guard abs(targetLevel - startLevel) > 0.001 else {
            currentMugFillLevel = targetLevel
            statusItem.button?.image = makeStatusIcon(for: state, badgeAngle: 0, mugFillLevel: currentMugFillLevel)
            return
        }

        mugFillAnimationStartLevel = startLevel
        mugFillAnimationTargetLevel = targetLevel
        mugFillAnimationStartTime = Date()
        mugFillAnimationDuration = 0.35
        mugFillAnimationState = state

        mugFillAnimationTimer = Timer.scheduledTimer(
            timeInterval: 1.0 / 30.0,
            target: self,
            selector: #selector(handleMugFillAnimationTick(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func handleMugFillAnimationTick(_ timer: Timer) {
        let elapsed = Date().timeIntervalSince(mugFillAnimationStartTime)
        let t = min(1.0, elapsed / mugFillAnimationDuration)
        // Smoothstep easing for a natural fill/empty feel.
        let eased = t * t * (3.0 - 2.0 * t)
        currentMugFillLevel = mugFillAnimationStartLevel + (mugFillAnimationTargetLevel - mugFillAnimationStartLevel) * eased
        statusItem.button?.image = makeStatusIcon(for: mugFillAnimationState, badgeAngle: 0, mugFillLevel: currentMugFillLevel)

        if t >= 1.0 {
            timer.invalidate()
            mugFillAnimationTimer = nil
        }
    }

    /// Ensure a badge CALayer exists on the status button and update its appearance.
    ///
    /// Sublayers are created lazily and cached; only their properties (color, contents)
    /// are mutated on subsequent calls. Sublayers are recreated only when switching
    /// between ring mode (checking/updating) and static-badge mode.
    private func updateBadgeLayer(for state: UpdateState) {
        let badgeSize: CGFloat = 11
        let badgeOutlineWidth: CGFloat = 0.5

        guard let button = statusItem.button else { return }

        // Create the container badge layer once.
        if badgeLayer == nil {
            let layer = CALayer()
            layer.bounds = CGRect(x: 0, y: 0, width: badgeSize, height: badgeSize)
            layer.masksToBounds = false
            layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            layer.zPosition = 1
            button.layer?.addSublayer(layer)
            badgeLayer = layer
        }

        guard let badgeLayer else { return }

        // Position the container layer (no implicit animation).
        let btnBounds = button.bounds
        let center = CGPoint(x: btnBounds.midX, y: btnBounds.midY)
        let x = center.x + badgeLayer.bounds.width / 2 + 1
        let y = center.y + badgeLayer.bounds.height / 2 + 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badgeLayer.position = CGPoint(x: x, y: y)

        let isRingState = state == .updating || state == .checking

        if isRingState {
            // --- Ring mode ---
            // Remove static-badge sublayers if they exist.
            if badgeBgShape != nil || badgeSymbolLayer != nil {
                badgeBgShape?.removeFromSuperlayer()
                badgeBgShape = nil
                badgeSymbolLayer?.removeFromSuperlayer()
                badgeSymbolLayer = nil
            }

            // Create the ring layer once; update its color on subsequent calls.
            if badgeRingLayer == nil {
                let ring = CAShapeLayer()
                let ringDiameter = badgeSize
                ring.bounds = CGRect(x: 0, y: 0, width: ringDiameter, height: ringDiameter)
                ring.position = CGPoint(x: badgeLayer.bounds.midX, y: badgeLayer.bounds.midY)
                let lineWidth: CGFloat = 2.0
                let ringCenter = CGPoint(x: ring.bounds.midX, y: ring.bounds.midY)
                let radius = (ringDiameter / 2) - lineWidth / 2
                // 70% arc (open ring), starting from top (−π/2), sweeping 252° (0.7 × 360°)
                let arcPath = CGMutablePath()
                arcPath.addArc(center: ringCenter, radius: radius,
                               startAngle: -.pi / 2,
                               endAngle: -.pi / 2 + 2 * .pi * 0.7,
                               clockwise: false)
                ring.path = arcPath
                ring.fillColor = nil
                ring.lineWidth = lineWidth
                ring.lineCap = .round
                ring.zPosition = 2
                badgeLayer.addSublayer(ring)
                badgeRingLayer = ring

                // Rotation animation — added once, removed when the layer is torn down.
                CATransaction.commit()
                let anim = CABasicAnimation(keyPath: "transform.rotation.z")
                anim.fromValue = 0
                anim.toValue = Double.pi * 2
                anim.duration = 1.0
                anim.repeatCount = .infinity
                anim.isRemovedOnCompletion = false
                ring.add(anim, forKey: "rotate")
                CATransaction.begin()
                CATransaction.setDisableActions(true)
            }

            // Update ring color in place.
            badgeRingLayer?.strokeColor = state.badgeColor.cgColor
            badgeLayer.isHidden = false

        } else {
            // --- Static-badge mode ---
            // Remove ring sublayer if it exists.
            if badgeRingLayer != nil {
                badgeRingLayer?.removeFromSuperlayer()
                badgeRingLayer = nil
            }

            let bgSize = CGSize(
                width: badgeLayer.bounds.width - badgeOutlineWidth,
                height: badgeLayer.bounds.height - badgeOutlineWidth
            )

            // Create the white background layer once.
            if badgeBgShape == nil {
                let bg = CAShapeLayer()
                bg.bounds = CGRect(origin: .zero, size: bgSize)
                bg.path = CGPath(ellipseIn: bg.bounds, transform: nil)
                bg.fillColor = NSColor.white.cgColor
                bg.strokeColor = NSColor.gray.cgColor
                bg.lineWidth = badgeOutlineWidth
                bg.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
                bg.shouldRasterize = false
                bg.zPosition = 0
                bg.position = CGPoint(x: badgeLayer.bounds.midX, y: badgeLayer.bounds.midY)
                badgeLayer.addSublayer(bg)
                badgeBgShape = bg
            }

            // Create the symbol layer once; update contents on subsequent calls.
            if badgeSymbolLayer == nil {
                let sym = CALayer()
                sym.bounds = CGRect(
                    x: -badgeOutlineWidth * 2.5, y: -badgeOutlineWidth * 2.5,
                    width: max(1, badgeLayer.bounds.width + badgeOutlineWidth * 2.5),
                    height: max(1, badgeLayer.bounds.height + badgeOutlineWidth * 2.5)
                )
                sym.zPosition = 1
                sym.contentsGravity = .resizeAspect
                sym.position = CGPoint(x: badgeLayer.bounds.midX, y: badgeLayer.bounds.midY)
                badgeLayer.addSublayer(sym)
                badgeSymbolLayer = sym
            }

            // Update symbol image and color in place.
            if let symbol = NSImage(systemSymbolName: state.badgeSymbolName, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: badgeSize, weight: .bold)
                let sym = symbol.withSymbolConfiguration(config) ?? symbol
                let badgeImage = Self.tintedImage(
                    sym,
                    color: state.badgeColor,
                    size: NSSize(width: badgeLayer.bounds.width, height: badgeLayer.bounds.height)
                )
                if let cg = badgeImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    badgeSymbolLayer?.contents = cg
                }
            }

            badgeLayer.isHidden = state == .unknown
        }

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

    // MARK: - Dock Icon

    private func setupDockIcons() {
        if let current = NSApp.applicationIconImage {
            defaultDockIcon = current
        } else {
            defaultDockIcon = NSImage(named: NSImage.applicationIconName)
        }

        if let defaultDockIcon {
            updatesAvailableDockIcon = makeUpdatesAvailableDockIcon(from: defaultDockIcon)
            NSApp.applicationIconImage = defaultDockIcon
        }

        dockIconMode = .default
        isUpdateCycleActive = false
    }

    private func updateDockIcon(for state: UpdateState) {
        // Centralized transition policy for dock icon behavior.
        switch state {
        case .updating:
            isUpdateCycleActive = true
            dockIconMode = .updatesAvailable
        case .updateComplete(let hasErrors):
            isUpdateCycleActive = false
            // Only show default icon if all updates were successful AND no packages remain.
            // If there are still packages available, keep showing the "updates available" icon.
            if hasErrors || !brewManager.packages.isEmpty {
                dockIconMode = .updatesAvailable
            } else {
                dockIconMode = .default
            }
        case .updatesAvailable:
            dockIconMode = .updatesAvailable
        case .upToDate:
            // Ignore stale `.upToDate` emissions while an update cycle is active.
            if !isUpdateCycleActive {
                dockIconMode = .default
            }
        default:
            break
        }

        switch dockIconMode {
        case .updatesAvailable:
            if let updatesAvailableDockIcon {
                NSApp.applicationIconImage = updatesAvailableDockIcon
            }
        case .default:
            if let defaultDockIcon {
                NSApp.applicationIconImage = defaultDockIcon
            }
        }
    }

    /// Creates a Dock icon variant with an empty mug symbol over the existing icon background.
    private func makeUpdatesAvailableDockIcon(from baseIcon: NSImage) -> NSImage {
        let size = baseIcon.size
        let result = NSImage(size: size)

        result.lockFocus()
        baseIcon.draw(in: NSRect(origin: .zero, size: size))

        if let symbol = NSImage(systemSymbolName: Constants.Symbols.baseUpdatesAvailable, accessibilityDescription: L10n.State.updatesAvailable) {
            let symbolPointSize = max(120, min(size.width, size.height) * 0.58)
            let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .bold)
            let configured = symbol.withSymbolConfiguration(config) ?? symbol
            let tinted = Self.tintedImage(configured, color: .white, size: NSSize(width: symbolPointSize, height: symbolPointSize))

            let symbolRect = NSRect(
                x: (size.width - symbolPointSize) / 2,
                y: (size.height - symbolPointSize) / 2,
                width: symbolPointSize,
                height: symbolPointSize
            )
            tinted.draw(in: symbolRect)
            Self.drawBeerFill(in: symbolRect, level: 0.2)
        }

        result.unlockFocus()
        result.isTemplate = false
        return result
    }

    /// Draws beer fill using three parts (bottom cap, middle, top cap) clipped to a
    /// rounded mug-interior shape so edges stay inside the mug contour.
    private static func drawBeerFill(in mugRect: NSRect, level: CGFloat) {
        let clampedLevel = max(0.0, min(1.0, level))
        guard clampedLevel > 0.001 else { return }

        // Approximate mug interior. Asymmetric insets avoid the handle area on the right.
        let leftInset = mugRect.width * 0.14
        let rightInset = mugRect.width * 0.31
        let interiorRect = NSRect(
            x: mugRect.minX + leftInset,
            y: mugRect.minY + mugRect.height * 0.135,
            width: max(1.0, mugRect.width - leftInset - rightInset),
            height: mugRect.height * 0.545
        )

        // Use mug-like rounded clipping to keep fill inside the interior contour.
        let cornerRadius = interiorRect.width * 0.20
        // Extend clipping slightly downward to avoid a 1px anti-alias seam at the mug floor.
        let clipBottomInset = max(0.35, mugRect.height * 0.015)
        let clipRect = NSRect(
            x: interiorRect.minX,
            y: interiorRect.minY - clipBottomInset,
            width: interiorRect.width,
            height: interiorRect.height + clipBottomInset
        )
        let interiorPath = NSBezierPath(
            roundedRect: clipRect,
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )

        NSGraphicsContext.saveGraphicsState()
        interiorPath.addClip()

        let beerHeight = max(3.0, interiorRect.height * clampedLevel)
        let liquidTop = min(interiorRect.maxY, interiorRect.minY + beerHeight)
        let capHeight = max(2.0, min(interiorRect.height * 0.34, beerHeight))

        NSColor.systemYellow.withAlphaComponent(1).setFill()

        // 1. Bottom cap: ellipse aligned to the mug bottom curvature.
        let bottomCapRect = NSRect(
            x: interiorRect.minX,
            y: interiorRect.minY - capHeight * 0.30,
            width: interiorRect.width,
            height: capHeight * 1.30
        )
        NSBezierPath(ovalIn: bottomCapRect).fill()

        // 2. Middle section: overlaps bottom/top ellipses by 50% of cap height.
        let middleBottom = interiorRect.minY + capHeight * 0.5
        let middleTop = liquidTop - capHeight * 0.5
        if middleTop > middleBottom {
            NSBezierPath(rect: NSRect(
                x: interiorRect.minX,
                y: middleBottom,
                width: interiorRect.width,
                height: middleTop - middleBottom
            )).fill()
        }

        // 3. Top cap: ellipse matching the mug's upper curvature.
        let topCapRect = NSRect(
            x: interiorRect.minX,
            y: liquidTop - capHeight,
            width: interiorRect.width,
            height: capHeight
        )
        NSBezierPath(ovalIn: topCapRect).fill()

        NSGraphicsContext.restoreGraphicsState()
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
