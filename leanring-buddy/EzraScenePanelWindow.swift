//
//  EzraScenePanelWindow.swift
//  leanring-buddy
//
//  Round 22: the window of one 3D scene. Until round 21 the scene's panel was a view in the overlay
//  window, which ignores the mouse, so the model could only be looked at. In its own window the paper
//  takes the mouse: a drag turns and tilts the model, a scroll or a pinch zooms it, and the small
//  toggle pulls it apart. The window never becomes the key window, so the keyboard stays with the app
//  the user is typing in, and it never activates Ezra.
//

import AppKit

/// A borderless, non-activating panel that holds one `EzraScenePanelView`. It sits at the overlay's
/// level, ordered just above the overlay window of its display, so it draws with the other marks.
final class EzraScenePanelWindow: NSPanel {
    let scenePanelView: EzraScenePanelView

    /// `frameOnScreen` is the panel view's whole frame (the paper and the room for its shadow) in
    /// global AppKit coordinates.
    init(scenePanelView: EzraScenePanelView, frameOnScreen: CGRect) {
        self.scenePanelView = scenePanelView
        super.init(
            contentRect: frameOnScreen,
            // A non-activating panel can take a click without making Ezra the active application.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        // The paper casts its own soft shadow inside the view.
        hasShadow = false
        // The overlay's own level, so the scene draws with the marks it was drawn with; it is ordered
        // above the overlay window when shown.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Ezra is almost never the active application; the scene must stay visible anyway.
        hidesOnDeactivate = false
        // The controller keeps the window until the scene's fade is over, then closes it.
        isReleasedWhenClosed = false
        // No window-server zoom or fade of its own: the panel view does the fading.
        animationBehavior = .none
        // Keeps the scene out of screenshots and screen sharing, like the status pill and the chat
        // panel. Ezra's own screenshots already leave out every window of this app.
        sharingType = .none
        // `ignoresMouseEvents` is left as AppKit sets it, so the window takes the mouse where it draws
        // something and lets clicks through where it is fully transparent; the panel view's hit test
        // takes only the paper.

        let containerView = EzraScenePanelWindowContentView(frame: CGRect(origin: .zero, size: frameOnScreen.size))
        contentView = containerView
        scenePanelView.frame = containerView.bounds
        containerView.addSubview(scenePanelView)
        scenePanelView.takesTheMouse = true
    }

    /// Never the key window: typing always goes to the app the user is in (and the chat panel's and
    /// dictation's idea of "the key window" is never this one).
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    /// Shows the window just above the overlay window of its display (nil: at the front of its level).
    func show(aboveOverlayWindow overlayWindow: NSWindow?) {
        orderFrontRegardless()
        if let overlayWindow {
            order(.above, relativeTo: overlayWindow.windowNumber)
        }
    }

    /// Moves and resizes the window when the paper grows a column of tags. The panel view lays itself
    /// out for the new size (`applyPanelLayout`); this only follows it on the screen.
    func moveAndResize(toFrameOnScreen frameOnScreen: CGRect) {
        setFrame(frameOnScreen, display: true)
    }

    /// Fades the scene out and closes the window when the fade is over. It stops taking the mouse at
    /// once, so a scene on its way out never catches a click meant for the app behind it.
    func fadeOutAndClose(fadeOutSeconds: Double) {
        ignoresMouseEvents = true
        scenePanelView.fadeOutAndRemove(fadeOutSeconds: fadeOutSeconds)
        guard fadeOutSeconds > 0 else {
            orderOut(nil)
            close()
            return
        }
        // The window is kept alive by this closure until the fade is over.
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeOutSeconds) {
            self.orderOut(nil)
            self.close()
        }
    }

    /// The drawing self test turns this on for its proof pictures alone (ScreenCaptureKit leaves out a
    /// window whose sharing type is none), and off again afterwards.
    func setVisibleInScreenCapturesForSelfTest(_ isVisibleInScreenCaptures: Bool) {
        sharingType = isVisibleInScreenCaptures ? .readOnly : .none
    }
}

/// The window's content: a plain container for the panel view. It takes no mouse of its own, so a
/// press outside the paper (the shadow's room) is the panel view's to refuse.
private final class EzraScenePanelWindowContentView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EzraScenePanelWindowContentView is only created in code")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only the panel view (over the paper), never the container itself.
        let hitView = super.hitTest(point)
        return hitView === self ? nil : hitView
    }
}
