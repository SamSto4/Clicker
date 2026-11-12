//
//  DesignSystem.swift
//  leanring-buddy
//
//  Centralized design system using a blue accent palette on dark surfaces,
//  with a unified button style system. All colors, button styles, and
//  interaction states are defined here as the single source of truth.
//

import SwiftUI
import AppKit

// MARK: - Design System Namespace

/// The top-level namespace for all design system tokens.
/// Usage: `DS.Colors.background`, `DS.Colors.accent`, etc.
enum DS {

    // MARK: - Color Tokens

    enum Colors {

        // ── Backgrounds ──────────────────────────────────────────────
        // Layered surfaces from deepest to most elevated.
        // Higher surfaces are lighter, creating a sense of depth.

        /// The deepest background — used for the main app window fill.
        static let background = Color(hex: "#101211")

        /// First elevation layer — used for cards, sidebar, top bar backgrounds.
        static let surface1 = Color(hex: "#171918")

        /// Second elevation layer — used for input fields, elevated cards, chat bubbles.
        static let surface2 = Color(hex: "#202221")

        /// Third elevation layer — used for hover backgrounds on interactive elements.
        static let surface3 = Color(hex: "#272A29")

        /// Fourth elevation layer — used for active/pressed states on interactive elements.
        static let surface4 = Color(hex: "#2E3130")

        // ── Borders ──────────────────────────────────────────────────

        /// Subtle border — used for card outlines, dividers, input field borders.
        static let borderSubtle = Color(hex: "#373B39")

        /// Strong border — used for focused inputs, hovered card outlines.
        static let borderStrong = Color(hex: "#444947")

        // ── Text ─────────────────────────────────────────────────────

        /// Primary text — main body text, titles, headings.
        static let textPrimary = Color(hex: "#ECEEED")

        /// Secondary text — descriptions, hints, muted labels.
        static let textSecondary = Color(hex: "#ADB5B2")

        /// Tertiary text — very muted, used for section labels, timestamps, disabled text.
        static let textTertiary = Color(hex: "#6B736F")

        /// Text used on top of the accent fill (#2563eb blue), like the primary button label.
        /// White on #2563eb achieves ~5.1:1 contrast — WCAG AA compliant.
        /// White on #1d4ed8 hover achieves ~6.5:1 — also WCAG AA compliant.
        static let textOnAccent: Color = .white

        // ── Tailwind Blue Scale ─────────────────────────────────────
        // Full Tailwind CSS v4 blue palette for consistent blue usage.
        //
        // Usage guide:
        //   50–100  → Very subtle tinted backgrounds (selected rows, hover fills on dark surfaces)
        //   200–300 → Light text/icons on dark backgrounds, disabled states
        //   400     → Bright accent text, links, icons, chat user bubbles
        //   500     → Mid-tone fills, badges, secondary buttons
        //   600     → Primary action fills (buttons, toggles) — main accent
        //   700     → Hover/pressed state for primary actions
        //   800–900 → Deep backgrounds, dark overlays, header bars
        //   950     → Deepest blue — near-black tinted backgrounds

        static let blue50  = Color(hex: "#eff6ff")
        static let blue100 = Color(hex: "#dbeafe")
        static let blue200 = Color(hex: "#bfdbfe")
        static let blue300 = Color(hex: "#93c5fd")
        static let blue400 = Color(hex: "#60a5fa")
        static let blue500 = Color(hex: "#3b82f6")
        static let blue600 = Color(hex: "#2563eb")
        static let blue700 = Color(hex: "#1d4ed8")
        static let blue800 = Color(hex: "#1e40af")
        static let blue900 = Color(hex: "#1e3a8a")
        static let blue950 = Color(hex: "#172554")

        // ── Accent (derived from blue scale) ───────────────────────
        // The primary fill is Blue 600; hover darkens to Blue 700.

        /// Accent fill — used for solid button backgrounds.
        /// #2563eb → ~5.1:1 contrast with white text (WCAG AA).
        static let accent = blue600

        /// Accent hover — slightly darker blue for hover state.
        /// #1d4ed8 → ~6.5:1 contrast with white text (WCAG AA+).
        static let accentHover = blue700

        /// Accent text — bright blue used for accent-colored text and icons
        /// on dark backgrounds (links, active nav items, highlighted labels).
        static let accentText = blue400

        /// Very subtle accent tint — used for selected item backgrounds (e.g. current step
        /// in the sidebar). Low opacity so it doesn't overpower.
        static let accentSubtle = blue500.opacity(0.10)

        // ── Semantic Colors ──────────────────────────────────────────

        /// Destructive/error actions — delete buttons, error messages, close button hover.
        static let destructive = Color(hex: "#E5484D")        // Radix Red 9

        /// Destructive hover state.
        static let destructiveHover = Color(hex: "#F2555A")   // Radix Red 10

        /// Destructive used for text on dark backgrounds (brighter for readability).
        static let destructiveText = Color(hex: "#FF6369")    // Radix Red 11

        /// Success — checkmarks, granted status, completion indicators.
        /// Independent green so success states are visually distinct from the blue accent.
        static let success = Color(hex: "#34D399")      // Tailwind Emerald 400

        /// Warning — caution messages, manual verification failure explanations.
        static let warning = Color(hex: "#FFB224")            // Radix Amber 9

        /// Warning text — brighter variant for text on dark backgrounds.
        static let warningText = Color(hex: "#F1A10D")        // Radix Amber 11

        /// Info/feature highlight — used for prompt card headers, code highlights.
        /// Lighter than accentText so informational elements are visually distinct
        /// from interactive accent-colored elements.
        static let info = Color(hex: "#70B8FF")               // Radix Blue 9

        /// Inline code text color — slightly brighter blue for monospace code snippets.
        static let codeText = Color(hex: "#9DC2FF")           // Radix Blue 11 variant

        // ── Overlay Cursor ───────────────────────────────────────────

        /// The blue cursor/bubble color used in OverlayWindow.
        /// Kept distinct from the accent since it serves a different purpose
        /// (screen overlay vs in-app UI).
        static let overlayCursorBlue = Color(hex: "#3380FF")

        /// The tint of the waveform, spinner and label while the user is dictating into a text
        /// field. Green, so dictating is never mistaken for asking Clicky (which is blue).
        static let overlayDictationAccent = Color(hex: "#2FCB9A")

        /// "Marker vermilion": the ink of the marks Clicky draws on the screen (arrows, circles,
        /// boxes, underlines, the edge of a label). A warm red-orange that stands out on white
        /// pages and dark editors alike, and cannot be mistaken for the blue cursor or the green
        /// of dictation.
        static let overlayDrawingInk = Color(hex: "#FF5A36")

        /// The highlighter band Clicky draws over text. Used see-through, so the text stays readable.
        static let overlayDrawingHighlighter = Color(hex: "#FFC400")

        /// The dark pill behind a drawn label, so its words can be read on any background.
        static let overlayDrawingLabelBackground = Color(hex: "#211A17")

        /// The words of a drawn label: a warm off-white on the dark pill.
        static let overlayDrawingLabelText = Color(hex: "#FFF6EF")

        /// The paper of a sticky note Clicky leaves on the screen: a soft yellow.
        static let overlayDrawingStickyNotePaper = Color(hex: "#FFE98A")

        /// The words on a sticky note: a dark warm brown, easy to read on the yellow paper.
        static let overlayDrawingStickyNoteText = Color(hex: "#3A2E0A")

        /// The light edge around the pen tip that leads each stroke while Clicky draws, so the
        /// ink-coloured tip can be told apart from the line it has just drawn.
        static let overlayDrawingPenEdge = Color(hex: "#FFF6EF")

        /// The paper of the explanation card Clicky writes on while it explains something: a
        /// warm cream, lighter and calmer than the yellow of a sticky note.
        static let overlayDrawingCardPaper = Color(hex: "#FBF5E6")

        /// The faint squared grid printed on the card's paper.
        static let overlayDrawingCardGridLine = Color(hex: "#EBE1C8")

        /// The thin edge around the card, so the cream paper ends clearly on a white page.
        static let overlayDrawingCardEdge = Color(hex: "#DDD0B2")

        /// The handwriting on the card: a dark warm brown, like soft pencil on cream paper.
        static let overlayDrawingCardText = Color(hex: "#2E2618")

        /// The pencil outline of the small boxes on the card.
        static let overlayDrawingCardPencil = Color(hex: "#5B4E3A")

        /// The light fill of an ordinary box on the card.
        static let overlayDrawingCardBoxFill = Color(hex: "#F1E5C4")

        /// The fill of a result box (the box an arrow leads to): a second soft tint, a pale
        /// green, so the outcome stands apart from what goes into it.
        static let overlayDrawingCardResultBoxFill = Color(hex: "#CFE7D4")

        /// The dates of a timeline on the card: the marker ink darkened until it reads easily as
        /// small handwriting on cream paper.
        static let overlayDrawingCardAccentText = Color(hex: "#C23F1D")

        // ── Status Pill ──────────────────────────────────────────────

        /// The status pill at the top of the screen on a display without a notch: almost black,
        /// used slightly see-through (see `DS.StatusPill.backgroundOpacity`).
        static let overlayStatusPillBackground = Color(hex: "#0E1010")

        /// The status pill under a notch: pure black, the colour of the notch itself, so the pill
        /// reads as a piece of the notch hanging down.
        static let overlayStatusPillNotchBackground = Color(hex: "#000000")

        /// A faint edge that keeps the dark pill visible on a dark page. Not used under a notch,
        /// where an edge would show the seam between the notch and the pill.
        static let overlayStatusPillBorder = Color(hex: "#343837")

        /// The word in the status pill: the panel's primary text colour, light on the dark pill.
        static let overlayStatusPillText = Color(hex: "#ECEEED")

        // ── Chat Panel ───────────────────────────────────────────────
        // The panel that drops down from the notch (tap option + command) to type to Clicky and to
        // browse past chats. Dark like the status pill it sits beside, so the two read as one family.

        /// The panel's surface on a display without a notch: almost black, used slightly see-through
        /// (see `DS.ChatPanel.backgroundOpacity`), the same colour as the status pill.
        static let chatPanelBackground = Color(hex: "#0E1010")

        /// The panel's surface under a notch: pure black, the colour of the notch itself, so the
        /// panel reads as a piece of the notch hanging down.
        static let chatPanelNotchBackground = Color(hex: "#000000")

        /// A faint edge that keeps the dark panel visible on a dark page. Not used under a notch,
        /// where an edge would show the seam between the notch and the panel.
        static let chatPanelBorder = Color(hex: "#343837")

        /// The thin lines between the panel's header, status row, messages and list rows.
        static let chatPanelDivider = Color(hex: "#232726")

        /// The box the text field and the search field sit in.
        static let chatPanelInputBackground = Color(hex: "#161918")

        /// The user's message bubble: the same deep blue as the help chat's user bubble.
        static let chatPanelUserBubble = Color(hex: "#1e40af")

        /// The words in the user's bubble.
        static let chatPanelUserBubbleText = Color(hex: "#F2F6FF")

        /// Clicky's reply text and the main words of a list row.
        static let chatPanelPrimaryText = Color(hex: "#ECEEED")

        /// Previews, times and hints.
        static let chatPanelSecondaryText = Color(hex: "#ADB5B2")

        /// The faintest words: project names, the footnote, the placeholder.
        static let chatPanelTertiaryText = Color(hex: "#6B736F")

        /// A list row or button under the mouse pointer.
        static let chatPanelRowHoverBackground = Color(hex: "#1A1D1C")

        /// The list row chosen with the arrow keys: a soft blue tint.
        static let chatPanelRowSelectedBackground = Color(hex: "#18233F")

        /// The mark on a kept chat (a filled pin).
        static let chatPanelKeptMark = Color(hex: "#FFB224")

        /// An error line in a chat ("i can't reach the internet right now.").
        static let chatPanelErrorText = Color(hex: "#FF6369")

        /// The word and live indicator in the panel while Clicky is thinking, in the asking blue.
        static let chatPanelAskingAccent = Color(hex: "#3380FF")

        /// The same, while dictating: the dictation green.
        static let chatPanelDictatingAccent = Color(hex: "#2FCB9A")

        // The tabs of the panel (round 15): chat, chats, memory, usage and settings.

        /// The tab that is showing: the same soft blue tint as the list row chosen with the arrow keys.
        static let chatPanelTabSelectedBackground = Color(hex: "#18233F")

        /// The word and icon of the tab that is showing.
        static let chatPanelTabSelectedText = Color(hex: "#7EB0FF")

        /// The track behind a row of choices ("sonnet | opus", "short | normal | long").
        static let chatPanelChoiceTrackBackground = Color(hex: "#161918")

        /// The choice that is on.
        static let chatPanelChoiceSelectedBackground = Color(hex: "#243B6B")

        /// A key of the shortcuts cheat sheet ("ctrl + option") and its edge.
        static let chatPanelKeycapBackground = Color(hex: "#1F2322")
        static let chatPanelKeycapBorder = Color(hex: "#3A403D")

        /// The dot and word of a permission that is granted, and of one that is not.
        static let chatPanelPermissionGrantedText = Color(hex: "#34D399")
        static let chatPanelPermissionMissingText = Color(hex: "#FFB224")

        /// The switch of a setting: its track when on (blue) and when off, and its knob. The panel
        /// draws its own switch because the system switch loses its colour in a window that is not
        /// the active one, which this panel almost always is, and on and off then look alike.
        static let chatPanelSwitchOnTrack = Color(hex: "#2563EB")
        static let chatPanelSwitchOffTrack = Color(hex: "#2B302E")
        static let chatPanelSwitchKnob = Color(hex: "#F2F6FF")

        // ── Floating Button Gradient ─────────────────────────────────

        /// The floating session button gradient colors (unchanged from original —
        /// this gradient is intentionally distinct from the rest of the palette
        /// to make the floating button stand out as a "jewel" on the desktop).
        static let floatingGradientPurple = Color(hex: "#8F46EB")
        static let floatingGradientPink = Color(hex: "#E84D9E")
        static let floatingGradientOrange = Color(hex: "#FF8C33")

        // ── Help Chat ──────────────────────────────────────────────

        /// User message bubble background in the help chat.
        /// Blue 800 — deep blue that's clearly distinct from the dark surface
        /// while keeping white text highly readable (~9:1 contrast).
        static let helpChatUserBubble = blue800

        /// Slightly lighter variant for hover/pressed states on user bubbles.
        static let helpChatUserBubbleHover = blue700

        /// Footer/backdrop behind the floating help chat.
        /// Slightly lighter than the main window background so the chat zone reads
        /// as a distinct docked surface even before the pill input is visible.
        static let helpChatBackdrop = Color(hex: "#212121")

        // ── Disabled State ───────────────────────────────────────────
        // Following Material Design 3's disabled pattern:
        // Container: onSurface at 12% opacity
        // Content: onSurface at 38% opacity

        /// Disabled button/container background.
        static var disabledBackground: Color {
            textPrimary.opacity(0.12)
        }

        /// Disabled text/icon color.
        static var disabledText: Color {
            textPrimary.opacity(0.38)
        }
    }

    // MARK: - Spacing (for reference, not enforced)

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: - Corner Radii

    enum CornerRadius {
        /// Small elements like tags, badges.
        static let small: CGFloat = 6
        /// Buttons, input fields, small cards.
        static let medium: CGFloat = 8
        /// Cards, dialogs, chat bubbles.
        static let large: CGFloat = 10
        /// Large panels, permission cards.
        static let extraLarge: CGFloat = 12
        /// Pill-shaped buttons (the continue button).
        static let pill: CGFloat = .infinity
    }

    // MARK: - Status Pill (the small state pill at the top of the screen)

    enum StatusPill {
        static let heightInPoints: CGFloat = 26
        static let horizontalPaddingInPoints: CGFloat = 12
        /// The room kept for the live indicator (bars, dots or wave) to the left of the word.
        static let indicatorWidthInPoints: CGFloat = 22
        static let indicatorHeightInPoints: CGFloat = 16
        static let indicatorToTextGapInPoints: CGFloat = 7
        /// A long notice is cut off with an ellipsis at this width instead of covering the menu bar.
        static let maximumWidthInPoints: CGFloat = 440
        /// The space between the menu bar and the pill on a display without a notch.
        static let gapBelowMenuBarInPoints: CGFloat = 6
        /// Under a notch the pill starts this far inside the notch, so no line of the page shows
        /// between the two.
        static let notchOverlapInPoints: CGFloat = 1
        static let screenEdgeMarginInPoints: CGFloat = 8
        /// The rounding of the two lower corners of a pill that hangs from a notch.
        static let notchCornerRadiusInPoints: CGFloat = 12
        static let borderWidthInPoints: CGFloat = 1
        static let backgroundOpacity: CGFloat = 0.94
        static let textFontSizeInPoints: CGFloat = 12

        /// The pill fades in and out this fast: quick enough to feel instant, slow enough not to pop.
        static let fadeSeconds: Double = 0.15

        // Listening bars: five thin bars whose height follows the microphone level.
        static let barCount = 5
        static let barWidthInPoints: CGFloat = 2.5
        static let barSpacingInPoints: CGFloat = 2
        static let barMinimumHeightInPoints: CGFloat = 4
        static let barMaximumHeightInPoints: CGFloat = 15
        /// The bars breathe a little even in silence, so the pill never looks frozen.
        static let barIdlePulseSmallestScale: CGFloat = 0.82
        static let barIdlePulseLargestScale: CGFloat = 1.12
        static let barIdlePulseSeconds: Double = 0.45
        static let barIdlePulseStaggerSeconds: Double = 0.09
        /// How fast a bar moves to a new height when the microphone level changes.
        static let barLevelChangeSeconds: Double = 0.09

        // Thinking dots: three dots that light up one after the other.
        static let dotCount = 3
        static let dotDiameterInPoints: CGFloat = 5
        static let dotSpacingInPoints: CGFloat = 3.5
        static let dotDimmestOpacity: Float = 0.28
        static let dotSmallestScale: CGFloat = 0.78
        static let dotPulseCycleSeconds: Double = 0.9
        static let dotPulseStaggerSeconds: Double = 0.16

        // Speaking wave: one smooth wave line that keeps travelling to the left.
        static let waveLineWidthInPoints: CGFloat = 2
        static let waveHeightInPoints: CGFloat = 9
        static let waveLengthInPoints: CGFloat = 11
        static let waveTravelSecondsPerWaveLength: Double = 0.55
    }

    // MARK: - Chat Panel (the panel that drops down from the notch)

    enum ChatPanel {
        // Window
        static let widthInPoints: CGFloat = 520
        /// The panel grows with its content up to this height, then its messages scroll.
        static let maximumHeightInPoints: CGFloat = 440
        /// The space between the menu bar and the panel on a display without a notch.
        static let gapBelowMenuBarInPoints: CGFloat = 6
        /// Under a notch the panel starts this far inside the notch, so no line of the page shows
        /// between the two (the status pill uses the same overlap).
        static let notchOverlapInPoints: CGFloat = 1
        static let screenEdgeMarginInPoints: CGFloat = 8
        /// The rounding of the two lower corners of a panel that hangs from a notch.
        static let notchCornerRadiusInPoints: CGFloat = 22
        /// The rounding of all four corners on a display without a notch.
        static let cornerRadiusInPoints: CGFloat = 18
        static let borderWidthInPoints: CGFloat = 1
        static let backgroundOpacity: CGFloat = 0.96

        // Opening and closing: a short fade with a small drop from the top edge.
        static let openSeconds: Double = 0.18
        static let closeSeconds: Double = 0.12
        static let dropDistanceInPoints: CGFloat = 10
        /// How long the window takes to follow a change of the content's height.
        static let resizeSeconds: Double = 0.16

        // Layout
        static let horizontalPaddingInPoints: CGFloat = 16
        static let headerTopPaddingInPoints: CGFloat = 14
        static let headerBottomPaddingInPoints: CGFloat = 12
        static let headerSpacingInPoints: CGFloat = 8
        static let statusRowHeightInPoints: CGFloat = 22
        static let bodyVerticalPaddingInPoints: CGFloat = 12
        static let messageSpacingInPoints: CGFloat = 14
        /// A message from the user is never wider than this, so a long line wraps inside a bubble.
        static let userBubbleMaximumWidthInPoints: CGFloat = 380
        static let userBubbleCornerRadiusInPoints: CGFloat = 12
        static let userBubbleHorizontalPaddingInPoints: CGFloat = 12
        static let userBubbleVerticalPaddingInPoints: CGFloat = 8

        // Text
        static let inputFontSizeInPoints: CGFloat = 14
        static let messageFontSizeInPoints: CGFloat = 13
        static let rowTitleFontSizeInPoints: CGFloat = 13
        static let rowDetailFontSizeInPoints: CGFloat = 11
        static let sectionTitleFontSizeInPoints: CGFloat = 10
        static let footnoteFontSizeInPoints: CGFloat = 10
        static let statusWordFontSizeInPoints: CGFloat = 11

        // The text field
        static let inputCornerRadiusInPoints: CGFloat = 10
        static let inputHorizontalPaddingInPoints: CGFloat = 12
        static let inputVerticalPaddingInPoints: CGFloat = 8
        /// A new line is added up to this many lines (shift + return), then the field scrolls.
        static let inputMaximumVisibleLineCount = 5

        // Buttons
        static let iconButtonSizeInPoints: CGFloat = 28
        static let iconButtonCornerRadiusInPoints: CGFloat = 8
        static let iconFontSizeInPoints: CGFloat = 12
        static let textActionFontSizeInPoints: CGFloat = 11
        static let textActionHorizontalPaddingInPoints: CGFloat = 8
        static let textActionVerticalPaddingInPoints: CGFloat = 4

        // The chat list
        static let listRowCornerRadiusInPoints: CGFloat = 8
        static let listRowHorizontalPaddingInPoints: CGFloat = 10
        static let listRowVerticalPaddingInPoints: CGFloat = 7
        static let listSectionTopPaddingInPoints: CGFloat = 10

        // The live word in the panel (thinking, listening, speaking, dictating)
        static let statusIndicatorWidthInPoints: CGFloat = 20
        static let statusIndicatorHeightInPoints: CGFloat = 12
        static let statusDotDiameterInPoints: CGFloat = 4.5
        static let statusDotSpacingInPoints: CGFloat = 3.5
        static let statusBarWidthInPoints: CGFloat = 2.5
        static let statusBarSpacingInPoints: CGFloat = 2
        static let statusPulseSeconds: Double = 0.9

        // The tab bar (round 15)
        static let tabBarTopPaddingInPoints: CGFloat = 10
        static let tabBarBottomPaddingInPoints: CGFloat = 4
        static let tabSpacingInPoints: CGFloat = 2
        static let tabHeightInPoints: CGFloat = 28
        static let tabCornerRadiusInPoints: CGFloat = 8
        static let tabIconFontSizeInPoints: CGFloat = 11
        static let tabLabelFontSizeInPoints: CGFloat = 12
        static let tabIconLabelSpacingInPoints: CGFloat = 5
        /// The space between the tab bar and the field or row under it.
        static let belowTabBarSpacingInPoints: CGFloat = 8

        // The memory, usage and settings tabs (round 15)
        static let tabSectionSpacingInPoints: CGFloat = 18
        static let tabSectionTitleBottomPaddingInPoints: CGFloat = 4
        static let memoryRowVerticalPaddingInPoints: CGFloat = 7
        static let memoryRowHorizontalPaddingInPoints: CGFloat = 10
        static let memoryRowTextMaximumLineCount = 4
        static let memoryRowActionSpacingInPoints: CGFloat = 4
        static let usageValueColumnWidthInPoints: CGFloat = 118
        static let usageRowSpacingInPoints: CGFloat = 7
        static let usageColumnSpacingInPoints: CGFloat = 12
        static let usageModelBlockTopPaddingInPoints: CGFloat = 10
        static let settingsRowVerticalPaddingInPoints: CGFloat = 6
        static let settingsRowIconWidthInPoints: CGFloat = 16
        static let switchTrackWidthInPoints: CGFloat = 34
        static let switchTrackHeightInPoints: CGFloat = 20
        static let switchKnobInsetInPoints: CGFloat = 2
        static let choiceFontSizeInPoints: CGFloat = 11
        static let choiceHorizontalPaddingInPoints: CGFloat = 10
        static let choiceVerticalPaddingInPoints: CGFloat = 5
        static let choiceCornerRadiusInPoints: CGFloat = 6
        static let choiceTrackPaddingInPoints: CGFloat = 2
        static let keycapFontSizeInPoints: CGFloat = 11
        static let keycapHorizontalPaddingInPoints: CGFloat = 7
        static let keycapVerticalPaddingInPoints: CGFloat = 3
        static let keycapCornerRadiusInPoints: CGFloat = 5
        static let keycapColumnWidthInPoints: CGFloat = 112
        static let permissionDotDiameterInPoints: CGFloat = 6
        /// A setting that cannot be changed now (typed replies while replies are not spoken) is dimmed to this.
        static let disabledRowOpacity: Double = 0.45
    }

    // MARK: - Animation Durations

    enum Animation {
        /// Quick state changes — hover in/out, press feedback.
        static let fast: Double = 0.15
        /// Standard transitions — content reveal, button state changes.
        static let normal: Double = 0.25
        /// Slower, more dramatic — fade-ins, celebration screen elements.
        static let slow: Double = 0.4
    }

    // MARK: - State Layer Opacities
    // Based on Material Design 3's state layer system.
    // A "state layer" overlays the button's content color at these opacities.

    enum StateLayer {
        /// Hover: subtle highlight to indicate interactivity.
        static let hover: Double = 0.08
        /// Focus: keyboard navigation indicator (slightly stronger than hover).
        static let focus: Double = 0.12
        /// Pressed: active press feedback (same strength as focus).
        static let pressed: Double = 0.12
        /// Dragged: strongest overlay (rarely used).
        static let dragged: Double = 0.16
    }
}

// MARK: - Button Styles

/// Primary button — the main call-to-action per screen.
/// Accent-colored background with white text. One per view maximum.
/// Used for: "start"/"resume", "let's go", "continue", "verify completion".
struct DSPrimaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    // Separate state for the scale expansion so it animates on a slower,
    // more gradual timeline (0.6s) than the background color snap (0.15s).
    @State private var isHoverScaleExpanded = false

    // Whether the hover glow shadow is active. Builds up gradually (0.6s)
    // on hover entry, fades out faster (0.3s) on exit.
    @State private var isHoverGlowActive = false

    // Continuously toggles while hovered to drive a gentle breathing pulse
    // in the glow shadow. Creates a living, organic feel — like the button
    // is softly glowing, not just statically lit.
    @State private var isGlowBreathingIn = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textOnAccent)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 14)
            .padding(.horizontal, isFullWidth ? 0 : 20)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            // Hover glow — builds up gradually, then gently breathes while hovered.
            // The breathing oscillates opacity and radius on a slow 2.5s loop,
            // creating a candle-flame-like "alive" quality rather than a static highlight.
            .shadow(
                color: DS.Colors.accent.opacity(
                    isHoverGlowActive ? (isGlowBreathingIn ? 0.32 : 0.18) : 0
                ),
                radius: isHoverGlowActive ? (isGlowBreathingIn ? 16 : 10) : 0
            )
            // Hover: gradually expand to 1.03. Press: snap down to 0.97.
            .scaleEffect(configuration.isPressed ? 0.97 : (isHoverScaleExpanded ? 1.03 : 1.0))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovering in
                // Background color — fast snap so the button feels responsive
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovered = hovering
                }

                // Scale — slow, gradual expansion (like the button is swelling)
                withAnimation(.easeInOut(duration: hovering ? 0.6 : 0.3)) {
                    isHoverScaleExpanded = hovering
                }

                // Glow — builds up gradually on entry, fades faster on exit
                withAnimation(.easeInOut(duration: hovering ? 0.6 : 0.3)) {
                    isHoverGlowActive = hovering
                }

                // Breathing glow loop — gentle pulse while hovered.
                // The 2.5s cycle keeps it feeling organic, not mechanical.
                if hovering {
                    withAnimation(
                        .easeInOut(duration: 2.5)
                        .repeatForever(autoreverses: true)
                    ) {
                        isGlowBreathingIn = true
                    }
                } else {
                    // Override the repeating animation with a finite one to stop cleanly
                    withAnimation(.easeOut(duration: 0.3)) {
                        isGlowBreathingIn = false
                    }
                }

                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            // Pressed: brighten slightly beyond hover
            return DS.Colors.accentHover.blendedWithWhite(fraction: DS.StateLayer.pressed)
        } else if isHovered {
            return DS.Colors.accentHover
        } else {
            return DS.Colors.accent
        }
    }
}

/// Secondary button — supporting actions, less visual weight than primary.
/// Surface-colored background with primary text. Used for: action buttons
/// (download, open link), embedded element buttons.
struct DSSecondaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 12)
            .padding(.horizontal, isFullWidth ? 0 : 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }
}

/// Tertiary/ghost button — low-emphasis actions with subtle hover background.
/// Transparent at rest, shows surface fill on hover. Used for: navigation
/// links, sidebar items, medium-low emphasis actions.
struct DSTertiaryButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(
                configuration.isPressed
                    ? DS.Colors.accentHover
                    : isHovered
                        ? DS.Colors.accentText
                        : DS.Colors.textSecondary
            )
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface3
        } else if isHovered {
            return DS.Colors.surface2
        } else {
            return Color.clear
        }
    }
}

/// Text button — the lowest-emphasis button style. No background on any
/// state, not even hover. Only the text color changes. Used for: "restart",
/// "skip", "cancel", and other truly minimal inline actions where a
/// background would add too much visual weight.
struct DSTextButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 14

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(
                configuration.isPressed
                    ? DS.Colors.textPrimary
                    : isHovered
                        ? DS.Colors.textPrimary
                        : DS.Colors.textTertiary
            )
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

/// Outlined button — medium emphasis, used where a border helps define
/// the button's bounds. Used for: display selector, copy prompt.
struct DSOutlinedButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 12)
            .padding(.horizontal, isFullWidth ? 0 : 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .stroke(
                        borderColor(isPressed: configuration.isPressed),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface3
        } else if isHovered {
            return DS.Colors.surface2
        } else {
            return DS.Colors.surface1
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        if isPressed || isHovered {
            return DS.Colors.borderStrong
        } else {
            return DS.Colors.borderSubtle
        }
    }
}

/// Destructive button — for dangerous/irreversible actions (close session, delete).
/// Red-tinted background that intensifies on hover and press.
struct DSDestructiveButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(
                isHovered || configuration.isPressed
                    ? .white
                    : DS.Colors.destructiveText
            )
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .stroke(
                        borderColor(isPressed: configuration.isPressed),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.destructive.opacity(0.40)
        } else if isHovered {
            return DS.Colors.destructive.opacity(0.30)
        } else {
            return DS.Colors.destructive.opacity(0.10)
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        if isPressed || isHovered {
            return DS.Colors.destructive.opacity(0.40)
        } else {
            return DS.Colors.destructive.opacity(0.15)
        }
    }
}

/// Icon-only button — compact circular button for utility actions.
/// Used for: close button (x), send message, small toolbar actions.
struct DSIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var isDestructiveOnHover: Bool = false
    var tooltipText: String? = nil

    /// Controls horizontal alignment of the tooltip relative to the button.
    /// Use `.leading` for buttons near the left edge of the window (tooltip extends right),
    /// `.trailing` for buttons near the right edge (tooltip extends left),
    /// and `.center` for buttons in the middle.
    var tooltipAlignment: Alignment = .center

    @State private var isHovered = false
    @State private var isTooltipVisible = false
    @State private var tooltipShowWorkItem: DispatchWorkItem? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundColor(iconColor(isPressed: configuration.isPressed))
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(circleBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Circle()
                    .stroke(circleBorderColor(isPressed: configuration.isPressed), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .contentShape(Circle())
            // Cursor change via AppKit cursor rects — more reliable than NSCursor.push/pop
            // because cursor rects are managed at the window level and don't conflict
            // with SwiftUI's internal cursor handling.
            .overlay(PointerCursorView())
            .onHover { hovering in
                isHovered = hovering
                // Show the tooltip after a delay (like native tooltips), hide immediately
                tooltipShowWorkItem?.cancel()
                if hovering {
                    let workItem = DispatchWorkItem {
                        withAnimation(.easeOut(duration: 0.15)) {
                            isTooltipVisible = true
                        }
                    }
                    tooltipShowWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
                } else {
                    withAnimation(.easeOut(duration: 0.1)) {
                        isTooltipVisible = false
                    }
                }
            }
            // Custom styled tooltip — positioned above the button with enough gap
            // to not overlap the button. Horizontally aligned based on tooltipAlignment
            // so tooltips near window edges don't clip outside the visible area.
            // Uses .allowsHitTesting(false) so the tooltip doesn't interfere
            // with the button's hover state.
            .overlay(
                Group {
                    if isTooltipVisible, let text = tooltipText, !text.isEmpty {
                        Text(text)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(DS.Colors.surface3.opacity(0.85))
                            )
                            .overlay(
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.white.opacity(0.20), lineWidth: 0.8)

                                    RoundedRectangle(cornerRadius: 6)
                                        .trim(from: 0, to: 0.5)
                                        .stroke(
                                            LinearGradient(
                                                colors: [
                                                    Color.white.opacity(0.10),
                                                    Color.white.opacity(0.02)
                                                ],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            ),
                                            lineWidth: 0.8
                                        )
                                }
                            )
                            .shadow(color: Color.black.opacity(0.42), radius: 14, x: 0, y: 8)
                            .shadow(color: Color.black.opacity(0.26), radius: 4, x: 0, y: 2)
                            .fixedSize()
                            .offset(y: -(size / 2 + 20))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                },
                alignment: tooltipAlignment
            )
    }

    private func iconColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover && (isHovered || isPressed) {
            return .white
        }
        if isPressed {
            return DS.Colors.textPrimary
        } else if isHovered {
            return DS.Colors.textPrimary
        } else {
            return DS.Colors.textSecondary
        }
    }

    private func circleBackgroundColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover {
            if isPressed {
                return DS.Colors.destructive.opacity(0.40)
            } else if isHovered {
                return DS.Colors.destructive.opacity(0.30)
            } else {
                return DS.Colors.surface2
            }
        }
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }

    private func circleBorderColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover && (isHovered || isPressed) {
            return DS.Colors.destructive.opacity(0.30)
        }
        if isPressed || isHovered {
            return DS.Colors.borderStrong
        } else {
            return DS.Colors.borderSubtle.opacity(0.5)
        }
    }
}

// MARK: - Convenience View Extensions

extension View {
    /// Applies the primary button style (accent-colored CTA).
    func dsPrimaryButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSPrimaryButtonStyle(isFullWidth: isFullWidth))
    }

    /// Applies the secondary button style (surface-colored supporting action).
    func dsSecondaryButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSSecondaryButtonStyle(isFullWidth: isFullWidth))
    }

    /// Applies the tertiary/ghost button style (subtle hover background).
    func dsTertiaryButtonStyle() -> some View {
        self.buttonStyle(DSTertiaryButtonStyle())
    }

    /// Applies the text-only button style (no background ever, just color change).
    func dsTextButtonStyle(fontSize: CGFloat = 14) -> some View {
        self.buttonStyle(DSTextButtonStyle(fontSize: fontSize))
    }

    /// Applies the outlined button style (bordered, medium emphasis).
    func dsOutlinedButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSOutlinedButtonStyle(isFullWidth: isFullWidth))
    }

    /// Applies the destructive button style (red-tinted danger action).
    func dsDestructiveButtonStyle() -> some View {
        self.buttonStyle(DSDestructiveButtonStyle())
    }

    /// Applies the icon-only button style (compact circle).
    /// `tooltipAlignment` controls where the tooltip sits horizontally relative to the button:
    /// `.leading` for left-edge buttons, `.trailing` for right-edge buttons, `.center` for middle.
    func dsIconButtonStyle(size: CGFloat = 28, isDestructiveOnHover: Bool = false, tooltip: String? = nil, tooltipAlignment: Alignment = .center) -> some View {
        self.buttonStyle(DSIconButtonStyle(size: size, isDestructiveOnHover: isDestructiveOnHover, tooltipText: tooltip, tooltipAlignment: tooltipAlignment))
    }

    /// Attaches the shared pointing-hand cursor treatment used across interactive controls.
    /// Disabled controls can opt out so they keep the default arrow cursor.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        self.overlay {
            if isEnabled {
                PointerCursorView()
            }
        }
    }
}

// MARK: - Buddy Composer Visual Style

enum BuddyComposerVisualStyle {
    static let waveformLeadingColor = Color(hex: "#F3FBFF")
    static let waveformTrailingColor = Color(hex: "#8FD2FF")
    static let waveformGlowColor = Color(hex: "#AEE3FF")
}

// MARK: - Pointer Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show a pointing hand cursor.
/// More reliable than NSCursor.push()/pop() inside SwiftUI's .onHover because
/// cursor rects are managed at the window level and don't conflict with
/// SwiftUI's internal cursor handling.
private class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return PointerCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - I-Beam Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show an I-beam (text selection) cursor.
/// Same approach as PointerCursorView — cursor rects are managed at the window level
/// and don't conflict with SwiftUI's internal cursor handling.
/// Unlike NSCursor.push()/pop() in .onHover, this avoids cursor stack imbalance
/// when the mouse moves quickly between views.
private class IBeamCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    /// Pass through all mouse events so the TextField underneath still receives
    /// focus, clicks, and text selection. Cursor rects are registered with the
    /// window (via resetCursorRects) and work independently of hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

struct IBeamCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return IBeamCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - Native Tooltip

/// Uses AppKit's `NSView.toolTip` to show a tooltip on hover.
/// SwiftUI's `.help()` conflicts with `.onHover` tracking areas, so
/// this bridges directly to AppKit's tooltip system which works independently.
private struct NativeTooltipView: NSViewRepresentable {
    let tooltip: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.toolTip = tooltip
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = tooltip
    }
}

extension View {
    /// Attaches a native macOS tooltip that works even alongside `.onHover`.
    func nativeTooltip(_ text: String?) -> some View {
        if let text = text, !text.isEmpty {
            return AnyView(self.overlay(NativeTooltipView(tooltip: text)))
        } else {
            return AnyView(self)
        }
    }
}

// MARK: - Color Utilities

extension Color {
    /// Create a Color from a hex string like "#FF5733" or "FF5733".
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }

    /// Returns a lighter version of this color by blending toward white.
    /// `fraction` is 0.0 (no change) to 1.0 (pure white).
    func blendedWithWhite(fraction: Double) -> Color {
        // Convert to NSColor to access RGB components for blending
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else { return self }

        let red = nsColor.redComponent + (1.0 - nsColor.redComponent) * fraction
        let green = nsColor.greenComponent + (1.0 - nsColor.greenComponent) * fraction
        let blue = nsColor.blueComponent + (1.0 - nsColor.blueComponent) * fraction

        return Color(red: red, green: green, blue: blue)
    }
}
