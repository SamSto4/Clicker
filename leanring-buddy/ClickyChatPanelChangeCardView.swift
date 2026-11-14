//
//  ClickyChatPanelChangeCardView.swift
//  leanring-buddy
//
//  The change card of the chat tab (round 17, file editing): what Clicky proposes to do to files,
//  shown as a diff with removed lines red and added lines green, and waiting for return ("apply"),
//  escape ("cancel"), or a spoken or typed yes or no. After an answer it shows the result, and for
//  30 minutes after an apply an "undo" button.
//
//  The view holds no state of its own: it draws `ClickyChangeCardState` from the view model and
//  every button goes back through the view model. The keys are handled by the panel's window
//  (`ClickyChatPanelController.handleKeyDown`), because while the card waits it, not the text
//  field, has the keyboard.
//

import SwiftUI

struct ClickyChatChangeCardView: View {
    @ObservedObject var viewModel: ClickyChatPanelViewModel
    let card: ClickyChangeCardState

    var body: some View {
        VStack(alignment: .leading, spacing: DS.ChatPanel.changeCardSectionSpacingInPoints) {
            headerRow

            if let lineText = card.lineText {
                Text(lineText)
                    .font(.system(size: DS.ChatPanel.messageFontSizeInPoints))
                    .foregroundColor(lineTextColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if showsDiff {
                ForEach(Array(card.content.sections.enumerated()), id: \.offset) { _, section in
                    sectionView(section)
                }
                if let hiddenLinesText = card.content.hiddenLinesText {
                    Text(hiddenLinesText)
                        .font(.system(size: DS.ChatPanel.rowDetailFontSizeInPoints))
                        .foregroundColor(DS.Colors.chatPanelTertiaryText)
                }
            }

            footerRow
        }
        .padding(DS.ChatPanel.changeCardPaddingInPoints)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.ChatPanel.changeCardCornerRadiusInPoints, style: .continuous)
                .fill(DS.Colors.chatPanelChangeCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.ChatPanel.changeCardCornerRadiusInPoints, style: .continuous)
                .stroke(DS.Colors.chatPanelChangeCardBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("proposed change")
    }

    // MARK: - Header and footer

    private var showsDiff: Bool {
        switch card.phase {
        case .awaitingAnswer, .applying, .applied:
            return true
        case .leftAlone, .undone, .notice:
            return false
        }
    }

    private var headerText: String? {
        switch card.phase {
        case .awaitingAnswer: return card.content.sections.count == 1 ? "change ready" : "\(card.content.sections.count) changes ready"
        case .applying: return "applying…"
        case .applied: return "applied"
        case .leftAlone: return "left alone"
        case .undone: return "undone"
        case .notice: return nil
        }
    }

    private var headerSymbolName: String {
        switch card.phase {
        case .awaitingAnswer, .applying: return "square.and.pencil"
        case .applied: return "checkmark.circle"
        case .leftAlone: return "xmark.circle"
        case .undone: return "arrow.uturn.backward.circle"
        case .notice: return "info.circle"
        }
    }

    private var lineTextColor: Color {
        switch card.phase {
        case .applied: return DS.Colors.chatPanelPermissionGrantedText
        case .awaitingAnswer where card.lineText != nil: return DS.Colors.chatPanelPermissionMissingText
        default: return DS.Colors.chatPanelSecondaryText
        }
    }

    @ViewBuilder
    private var headerRow: some View {
        if let headerText {
            HStack(spacing: 6) {
                Image(systemName: headerSymbolName)
                    .font(.system(size: DS.ChatPanel.iconFontSizeInPoints, weight: .medium))
                    .foregroundColor(DS.Colors.chatPanelAskingAccent)
                Text(headerText)
                    .font(.system(size: DS.ChatPanel.changeCardTitleFontSizeInPoints, weight: .semibold))
                    .foregroundColor(DS.Colors.chatPanelPrimaryText)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var footerRow: some View {
        switch card.phase {
        case .awaitingAnswer:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button(action: { viewModel.requestApplyPendingChange() }) {
                        Text("apply ⏎")
                    }
                    .buttonStyle(ClickyChatTextButtonStyle(isProminent: true))
                    .accessibilityLabel("apply the change")

                    Button(action: { viewModel.requestCancelPendingChange() }) {
                        Text("cancel esc")
                    }
                    .buttonStyle(ClickyChatTextButtonStyle())
                    .accessibilityLabel("cancel the change")

                    Spacer(minLength: 0)
                }
                // After another turn a spoken yes or no no longer answers the card (it could answer
                // something else Clicky asked), so the hint goes; return and the buttons still work.
                if card.acceptsSpokenAnswer {
                    Text("or say yes or no")
                        .font(.system(size: DS.ChatPanel.changeCardKeyHintFontSizeInPoints))
                        .foregroundColor(DS.Colors.chatPanelTertiaryText)
                }
            }
        case .applied:
            HStack(spacing: 8) {
                Button(action: { viewModel.requestUndoAppliedChange() }) {
                    Text("undo")
                }
                .buttonStyle(ClickyChatTextButtonStyle())
                .accessibilityLabel("undo the change")
                Text("or say undo that")
                    .font(.system(size: DS.ChatPanel.changeCardKeyHintFontSizeInPoints))
                    .foregroundColor(DS.Colors.chatPanelTertiaryText)
                Spacer(minLength: 0)
            }
        case .applying, .leftAlone, .undone, .notice:
            EmptyView()
        }
    }

    // MARK: - One changed file

    private func sectionView(_ section: ClickyChangeCardSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(section.actionTitle)
                    .font(.system(size: DS.ChatPanel.sectionTitleFontSizeInPoints, weight: .semibold))
                    .tracking(0.4)
                    .foregroundColor(DS.Colors.chatPanelTertiaryText)
                Text(section.relativePath)
                    .font(.system(size: DS.ChatPanel.rowTitleFontSizeInPoints, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.chatPanelPrimaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if !section.summary.isEmpty {
                Text(section.summary)
                    .font(.system(size: DS.ChatPanel.rowDetailFontSizeInPoints))
                    .foregroundColor(DS.Colors.chatPanelSecondaryText)
            }
            if let noteText = section.noteText {
                Text(noteText)
                    .font(.system(size: DS.ChatPanel.rowDetailFontSizeInPoints))
                    .foregroundColor(DS.Colors.chatPanelTertiaryText)
            }
            if !section.diffLines.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(section.diffLines.enumerated()), id: \.offset) { _, diffLine in
                        diffLineView(diffLine)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DS.ChatPanel.diffCornerRadiusInPoints, style: .continuous))
            }
        }
    }

    private func diffLineView(_ diffLine: ClickyDiffLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(lineNumberText(for: diffLine))
                .font(.system(size: DS.ChatPanel.diffFontSizeInPoints, design: .monospaced))
                .foregroundColor(DS.Colors.chatPanelTertiaryText)
                .frame(width: DS.ChatPanel.diffLineNumberWidthInPoints, alignment: .trailing)
            Text(markerText(for: diffLine))
                .font(.system(size: DS.ChatPanel.diffFontSizeInPoints, weight: .bold, design: .monospaced))
                .foregroundColor(textColor(for: diffLine))
                .frame(width: 14)
            Text(diffLine.kind == .hunkSeparator ? "…" : (diffLine.text.isEmpty ? " " : diffLine.text))
                .font(.system(size: DS.ChatPanel.diffFontSizeInPoints, design: .monospaced))
                .foregroundColor(textColor(for: diffLine))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.ChatPanel.diffLineHorizontalPaddingInPoints)
        .padding(.vertical, DS.ChatPanel.diffLineVerticalPaddingInPoints)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor(for: diffLine))
    }

    private func lineNumberText(for diffLine: ClickyDiffLine) -> String {
        guard let lineNumber = diffLine.newLineNumber ?? diffLine.oldLineNumber else { return "" }
        return String(lineNumber)
    }

    private func markerText(for diffLine: ClickyDiffLine) -> String {
        switch diffLine.kind {
        case .added: return "+"
        case .removed: return "−"
        case .context, .hunkSeparator: return " "
        }
    }

    private func textColor(for diffLine: ClickyDiffLine) -> Color {
        switch diffLine.kind {
        case .added: return DS.Colors.chatPanelDiffAddedText
        case .removed: return DS.Colors.chatPanelDiffRemovedText
        case .context, .hunkSeparator: return DS.Colors.chatPanelDiffContextText
        }
    }

    private func backgroundColor(for diffLine: ClickyDiffLine) -> Color {
        switch diffLine.kind {
        case .added: return DS.Colors.chatPanelDiffAddedBackground
        case .removed: return DS.Colors.chatPanelDiffRemovedBackground
        case .context, .hunkSeparator: return Color.clear
        }
    }
}
