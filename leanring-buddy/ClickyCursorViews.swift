//
//  ClickyCursorViews.swift
//  leanring-buddy
//
//  The cursor's own drawings (round 20, the cursor studio): the shape in its style, the waveform
//  shown while the user speaks, and the spinner shown while Clicky thinks. The overlay draws the
//  real cursor with these views and the LOOK section of the settings tab draws its preview with the
//  very same ones, so the preview shows exactly what the cursor looks like. They live apart from
//  OverlayWindow.swift (whose views need the whole `CompanionManager`) so the chat panel and the
//  offscreen renders can use them on their own.
//

import SwiftUI

/// One of the cursor's five shapes, from the outline in ClickyCore (`ClickyCursorShapeGeometry`).
/// The triangle is today's `Triangle` to the digit: the same three points, added in the same order.
struct ClickyCursorShapeView: Shape {
    let shape: ClickyCursorShape

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for outlinePart in ClickyCursorShapeGeometry.outline(for: shape, in: rect).parts {
            switch outlinePart {
            case .move(let point):
                path.move(to: point)
            case .line(let point):
                path.addLine(to: point)
            case .arc(let center, let radius, let startDegrees, let endDegrees):
                path.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(startDegrees),
                    endAngle: .degrees(endDegrees),
                    clockwise: false
                )
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }
}

/// The cursor's shape in its colour and in its square frame: filled, or drawn as a line with round
/// caps and joins for the ring and the chevron. The overlay puts the rotation, the glow and the
/// flight scale around it; the LOOK preview puts the rest angle and the same glow around it.
struct ClickyStyledCursorShapeView: View {
    let cursorStyle: ClickyCursorStyle
    let cursorColour: Color

    private var frameSideInPoints: CGFloat {
        CGFloat(cursorStyle.size.frameSideInPoints)
    }

    var body: some View {
        Group {
            if cursorStyle.shape.isStroked {
                ClickyCursorShapeView(shape: cursorStyle.shape)
                    .stroke(
                        cursorColour,
                        style: StrokeStyle(
                            lineWidth: frameSideInPoints * CGFloat(cursorStyle.shape.strokeWidthShare),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
            } else {
                ClickyCursorShapeView(shape: cursorStyle.shape)
                    .fill(cursorColour)
            }
        }
        .frame(width: frameSideInPoints, height: frameSideInPoints)
    }
}

/// The glow around the cursor's shape: the style's glow at a flight scale (1 at rest, up to 1.3
/// mid-flight), and for a strong glow a second, wider and fainter halo. A soft glow is today's one
/// shadow (the colour at full opacity, radius 8 + (scale − 1) × 20); its second shadow is clear with
/// radius 0, which draws nothing.
struct ClickyCursorGlowModifier: ViewModifier {
    let cursorGlow: ClickyCursorGlow
    let cursorColour: Color
    let flightScale: CGFloat

    func body(content: Content) -> some View {
        content
            .shadow(
                color: cursorColour.opacity(cursorGlow.cursorGlowOpacity),
                radius: cursorGlow.cursorGlowRadius(atFlightScale: flightScale),
                x: 0,
                y: 0
            )
            .shadow(
                color: cursorGlow.hasWideSecondGlow ? cursorColour.opacity(cursorGlow.wideSecondGlowOpacity) : .clear,
                radius: cursorGlow.wideSecondGlowRadius(atFlightScale: flightScale),
                x: 0,
                y: 0
            )
    }
}

// MARK: - Waveform

/// A small waveform that replaces the cursor while the user is holding the push-to-talk shortcut and
/// speaking. Moved here from OverlayWindow.swift in round 20 (it was the private
/// `BlueCursorWaveformView`) so the LOOK preview can show it; its bars and timing are unchanged. The
/// glow and the scale come from the style, and their defaults are today's (radius 6, opacity 0.6,
/// no scaling).
struct ClickyCursorWaveformView: View {
    let audioPowerLevel: CGFloat
    var barColor: Color = DS.Colors.overlayCursorBlue
    var glowRadius: CGFloat = 6
    var glowOpacity: Double = 0.6
    var scale: CGFloat = 1

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timelineContext in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(barColor)
                        .frame(
                            width: 2,
                            height: barHeight(
                                for: barIndex,
                                timelineDate: timelineContext.date
                            )
                        )
                }
            }
            .shadow(color: barColor.opacity(glowOpacity), radius: glowRadius, x: 0, y: 0)
            .animation(.linear(duration: 0.08), value: audioPowerLevel)
        }
        // The style's size scales the whole waveform, so its own numbers stay as they are.
        .scaleEffect(scale)
    }

    private func barHeight(for barIndex: Int, timelineDate: Date) -> CGFloat {
        let animationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * 3.6) + CGFloat(barIndex) * 0.35
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 10 * listeningBarProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 1.5
        return 3 + reactiveHeight + idlePulse
    }
}

// MARK: - Spinner

/// A small spinning indicator that replaces the cursor while the AI is working on an answer. Moved
/// here from OverlayWindow.swift in round 20 (it was the private `BlueCursorSpinnerView`) so the LOOK
/// preview can show it; its ring and timing are unchanged. The glow and the scale come from the
/// style, and their defaults are today's (radius 6, opacity 0.6, no scaling).
struct ClickyCursorSpinnerView: View {
    var spinnerColor: Color = DS.Colors.overlayCursorBlue
    var glowRadius: CGFloat = 6
    var glowOpacity: Double = 0.6
    var scale: CGFloat = 1
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [
                        spinnerColor.opacity(0.0),
                        spinnerColor
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: spinnerColor.opacity(glowOpacity), radius: glowRadius, x: 0, y: 0)
            // The style's size scales the whole spinner, so its own numbers stay as they are.
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}
