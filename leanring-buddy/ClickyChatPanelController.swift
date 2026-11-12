//
//  ClickyChatPanelController.swift
//  leanring-buddy
//
//  The chat panel's window and its life: it hangs from the notch (or sits below the menu bar),
//  fades in on a clean tap of option + command, takes the keyboard without making Clicky the
//  active app, follows the height of its content, and closes on Escape or a click outside, giving
//  the keyboard back to the app the user was in.
//
//  The panel is its own borderless window. Its SwiftUI content is the window's own hosting view;
//  nothing is ever added to an existing hosting view by hand.
//

import AppKit
import Combine
import SwiftUI

/// The panel's window. Borderless and see-through, at the status pill's level, on every Space and
/// over full-screen apps. Unlike the pill it may become the key window, because the text field
/// needs the keyboard, but it is non-activating: showing it never makes Clicky the active app, so
/// the app the user was typing in stays frontmost behind it.
final class ClickyChatPanelWindow: NSPanel {
    /// Asked first about every key press. Returns true when the key was handled and must go no
    /// further (Escape, and the arrow keys and Return in the chat list).
    var keyEventInterceptor: ((NSEvent) -> Bool)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: DS.ChatPanel.widthInPoints, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // The same level as the status pill: just above the menu bar, below the menus that open from it.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        // The panel's own fade does the showing and hiding, with no zoom from the window server.
        animationBehavior = .none
        // Keeps the panel out of screenshots and screen sharing. Clicky's own screenshots already
        // leave out every window of this app; this covers every other capture as well.
        sharingType = .none
    }

    /// True while the panel is the key window, so dictation can tell that a paste belongs in the
    /// panel's text field and not in the app behind it.
    private(set) static var isTheKeyWindow = false

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func becomeKey() {
        super.becomeKey()
        Self.isTheKeyWindow = true
    }

    override func resignKey() {
        super.resignKey()
        Self.isTheKeyWindow = false
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let keyEventInterceptor, keyEventInterceptor(event) {
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class ClickyChatPanelController {
    /// The design system's sizes, in the form the placement maths takes them.
    static let layoutMetrics = ClickyChatPanelMetrics(
        widthInPoints: Double(DS.ChatPanel.widthInPoints),
        maximumHeightInPoints: Double(DS.ChatPanel.maximumHeightInPoints),
        gapBelowMenuBarInPoints: Double(DS.ChatPanel.gapBelowMenuBarInPoints),
        notchOverlapInPoints: Double(DS.ChatPanel.notchOverlapInPoints),
        screenEdgeMarginInPoints: Double(DS.ChatPanel.screenEdgeMarginInPoints)
    )

    let viewModel: ClickyChatPanelViewModel

    private(set) var isOpen = false

    /// Called with true when the panel has opened and false when it has closed, so the status pill
    /// can hide while the panel is up and come back after.
    var openStateChangedHandler: ((Bool) -> Void)?

    /// Which screen the panel opens on: the one under the mouse. Replaced in the self test.
    var screenProvider: () -> NSScreen? = {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The geometry the panel is placed with (the screen's frame, notch and menu bar). Replaced
    /// only by the offscreen check that runs this very controller (see `ClickyChatPanelController`
    /// in the round 15 live-size render), so the window can be placed where nobody sees it.
    var screenGeometryProvider: (NSScreen) -> ClickyStatusPillScreenGeometry = { screen in
        ClickyStatusPillController.screenGeometry(for: screen)
    }

    /// Escape was pressed in the panel. The manager decides: stop the running turn, or close.
    /// Without a handler Escape simply closes the panel.
    var escapePressedHandler: (() -> Void)?

    private var panel: ClickyChatPanelWindow?
    private var clickOutsideMonitor: Any?
    private var contentHeightCancellable: AnyCancellable?
    private var applicationFrontmostBeforeOpening: NSRunningApplication?
    private var shownOnScreen: NSScreen?

    /// The frame the window was last asked to have: where its resize is heading, which is not
    /// where the window is while the 0.16 s animation is still running. A new height is compared
    /// with this and not with the window's current frame. Comparing with the current frame
    /// dropped a request that came while an earlier one was still starting to move: the usage tab
    /// first shows "reading the logs…" (a short panel), and its data arrived a few milliseconds
    /// later and asked for the height the window still had, so the grow was thrown away as "no
    /// change" and the window finished shrinking to the short height, with the tab's content
    /// hanging out of it.
    private var lastRequestedPanelFrame: NSRect?

    /// Counts every open and close. The work that takes the window off the screen after the fade
    /// carries the number it was scheduled with and does nothing if the panel opened again.
    private var visibilityGeneration = 0

    init(viewModel: ClickyChatPanelViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Opening and closing

    func toggle() {
        if isOpen {
            close()
        } else {
            open()
        }
    }

    /// Opens the panel. `takingKeyboard` is false when it opens only to show a reply that is not
    /// spoken ("speak replies" is off): it is then ordered to the front without becoming the key
    /// window, so the app the user is typing in keeps the keyboard.
    func open(takingKeyboard: Bool = true) {
        guard !isOpen else { return }
        guard let screen = screenProvider() else { return }

        isOpen = true
        visibilityGeneration += 1
        shownOnScreen = screen

        // Remember who had the keyboard: the panel never activates Clicky, so that app is still
        // frontmost, and it is handed the keyboard back when the panel closes.
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        applicationFrontmostBeforeOpening = frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? nil
            : frontmostApplication

        let screenGeometry = screenGeometryProvider(screen)
        viewModel.hangsFromNotch = screenGeometry.hasNotch
        viewModel.panelWillOpen(requestsKeyboardFocus: takingKeyboard)

        let panel = existingOrNewPanel()
        let finalFrame = placement(forContentHeightInPoints: viewModel.desiredPanelHeightInPoints, on: screen).frame

        // It drops in from just above its final place while it fades in.
        panel.alphaValue = 0
        lastRequestedPanelFrame = finalFrame
        panel.setFrame(finalFrame.offsetBy(dx: 0, dy: DS.ChatPanel.dropDistanceInPoints), display: false)
        if takingKeyboard {
            panel.makeKeyAndOrderFront(nil)
        }
        // Clicky is almost never the active app, so the panel is also ordered in explicitly.
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { animationContext in
            animationContext.duration = DS.ChatPanel.openSeconds
            animationContext.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }

        installClickOutsideMonitor()
        // The view reports its height again whenever its content changes; the window follows. The
        // value that arrives is used, because a @Published property still holds the old value
        // while its publisher is sending the new one.
        contentHeightCancellable = viewModel.$desiredPanelHeightInPoints
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] desiredHeightInPoints in
                self?.followContentHeight(desiredHeightInPoints, animated: true)
            }

        if takingKeyboard {
            viewModel.requestInputFocus()
        }
        openStateChangedHandler?(true)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        visibilityGeneration += 1
        let generationWhenClosed = visibilityGeneration

        removeClickOutsideMonitor()
        contentHeightCancellable = nil

        if let panel {
            NSAnimationContext.runAnimationGroup { animationContext in
                animationContext.duration = DS.ChatPanel.closeSeconds
                animationContext.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }
            // A work item on the main queue, like the status pill's: it runs on the main thread
            // and so may touch the panel directly.
            DispatchQueue.main.asyncAfter(deadline: .now() + DS.ChatPanel.closeSeconds) { [weak self] in
                guard let self, self.visibilityGeneration == generationWhenClosed else { return }
                self.panel?.orderOut(nil)
            }
        }

        handKeyboardBackToPreviousApplication()
        openStateChangedHandler?(false)
    }

    /// The panel is non-activating, so the app the user was in normally never lost the keyboard.
    /// If Clicky did become active (the user clicked the menu bar panel meanwhile), that app is
    /// brought back.
    private func handKeyboardBackToPreviousApplication() {
        guard NSApp.isActive, let applicationFrontmostBeforeOpening, !applicationFrontmostBeforeOpening.isTerminated else {
            return
        }
        applicationFrontmostBeforeOpening.activate()
    }

    // MARK: - Self test

    /// Lets Clicky's own proof picture (the panel self test) contain the panel. Normally the
    /// panel is hidden from every capture; the self test is the one place where seeing it in a
    /// capture is the point.
    func setVisibleInScreenCapturesForSelfTest(_ isVisibleInScreenCaptures: Bool) {
        existingOrNewPanel().sharingType = isVisibleInScreenCaptures ? .readOnly : .none
    }

    // MARK: - Window

    private func existingOrNewPanel() -> ClickyChatPanelWindow {
        if let panel {
            return panel
        }
        let newPanel = ClickyChatPanelWindow()
        let hostingView = NSHostingView(rootView: ClickyChatPanelView(viewModel: viewModel))
        // The window's size is set here, from the content's reported height. The hosting view
        // must not push minimum or maximum sizes onto the window itself.
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: newPanel.frame.size)
        hostingView.autoresizingMask = [.width, .height]
        newPanel.contentView = hostingView
        newPanel.keyEventInterceptor = { [weak self] keyEvent in
            self?.handleKeyDown(keyEvent) ?? false
        }
        panel = newPanel
        return newPanel
    }

    private func placement(forContentHeightInPoints contentHeightInPoints: CGFloat, on screen: NSScreen) -> ClickyChatPanelPlacement {
        ClickyChatPanelLayout.placement(
            forContentHeightInPoints: Double(contentHeightInPoints),
            screenGeometry: screenGeometryProvider(screen),
            metrics: Self.layoutMetrics
        )
    }

    private func followContentHeight(_ desiredHeightInPoints: CGFloat, animated: Bool) {
        guard isOpen, let panel, let shownOnScreen else { return }
        let newFrame = placement(forContentHeightInPoints: desiredHeightInPoints, on: shownOnScreen).frame
        guard newFrame != lastRequestedPanelFrame else { return }
        lastRequestedPanelFrame = newFrame
        if animated && panel.isVisible {
            NSAnimationContext.runAnimationGroup { animationContext in
                animationContext.duration = DS.ChatPanel.resizeSeconds
                animationContext.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(newFrame, display: true)
            }
        } else {
            panel.setFrame(newFrame, display: true)
        }
    }

    // MARK: - Keys

    /// Escape in every screen, and the arrow keys and Return in the chat list. Returns true when
    /// the key was used up.
    private func handleKeyDown(_ keyEvent: NSEvent) -> Bool {
        // While an input method is composing text, Return and Escape belong to the input method.
        if let focusedTextView = panel?.firstResponder as? NSTextView, focusedTextView.hasMarkedText() {
            return false
        }

        let escapeKeyCode: UInt16 = 53
        let returnKeyCode: UInt16 = 36
        let keypadEnterKeyCode: UInt16 = 76
        let upArrowKeyCode: UInt16 = 126
        let downArrowKeyCode: UInt16 = 125

        if keyEvent.keyCode == escapeKeyCode {
            if let escapePressedHandler {
                escapePressedHandler()
            } else {
                close()
            }
            return true
        }

        guard viewModel.screen == .chatList else { return false }
        let hasModifierHeld = !keyEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        guard !hasModifierHeld else { return false }

        switch keyEvent.keyCode {
        case upArrowKeyCode:
            viewModel.moveSelection(.up)
            return true
        case downArrowKeyCode:
            viewModel.moveSelection(.down)
            return true
        case returnKeyCode, keypadEnterKeyCode:
            viewModel.openSelectedChatToRead()
            return true
        default:
            return false
        }
    }

    // MARK: - Click outside

    /// A click anywhere outside the panel closes it, the way a pop-up menu goes away. The monitor
    /// only exists while the panel is open, so a closed panel costs nothing and can never take a
    /// click.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isOpen, let panel = self.panel else { return }
                guard !panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.close()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
    }
}
