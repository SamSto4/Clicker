//
//  EzraChatPanelContextView.swift
//  leanring-buddy
//
//  The "context" tab of the chat panel (round 21b): standing context the user writes for Ezra (who
//  they are, what they work on, how they want answers), which Ezra reads on every turn, typed and
//  spoken. Sam's mockup: a heading, a big editor, and under it the character count ("96 / 2000"), the
//  save mark ("saved ✓") and "clear", which asks "clear everything?" in place (never an alert).
//
//  The words are saved as the user types (0.8 s after the last keystroke) by the store the view model
//  holds; this view only shows the state. A line that looks like a key or a card number stays in the
//  user's file but never reaches Ezra, and the amber line under the editor names it.
//
//  Every colour and size is a `DS` token; the buttons use the panel's own button styles (hover and the
//  pointing hand). The editor shows the I-beam of its text view. The count, the save mark and the
//  warnings are not interactive.
//

import SwiftUI

struct EzraChatPanelContextContentView: View {
    @ObservedObject var viewModel: EzraChatPanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.ChatPanel.contextSectionSpacingInPoints) {
            sectionTitle

            if viewModel.agentContextStore == nil {
                Text(EzraAgentContextTabText.noContextFolderText)
                    .font(.system(size: DS.ChatPanel.messageFontSizeInPoints))
                    .foregroundColor(DS.Colors.chatPanelSecondaryText)
                    .padding(.horizontal, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
            } else {
                editorBox
                counterAndClearRow
                if let hiddenLinesWarningText = viewModel.agentContextHiddenLinesWarningText {
                    warningLine(hiddenLinesWarningText)
                }
                if let agentContextLoadNotice = viewModel.agentContextLoadNotice {
                    warningLine(agentContextLoadNotice)
                }
            }
        }
    }

    // MARK: - Title

    /// "CONTEXT · ezra reads this every turn", in the settings tab's section title look, the dot and
    /// the second part dimmer.
    private var sectionTitle: some View {
        (
            Text(EzraAgentContextTabText.sectionTitleText)
                .font(.system(size: DS.ChatPanel.sectionTitleFontSizeInPoints, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(DS.Colors.chatPanelTertiaryText)
            + Text(" · " + EzraAgentContextTabText.sectionSubtitleText)
                .font(.system(size: DS.ChatPanel.sectionTitleFontSizeInPoints, weight: .regular))
                .foregroundColor(DS.Colors.chatPanelTertiaryText.opacity(DS.ChatPanel.contextTitleSubtitleOpacity))
        )
        .padding(.horizontal, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
        .accessibilityElement(children: .combine)
    }

    // MARK: - The editor

    /// The editor, a fixed height with the panel's input corners and background; it scrolls inside, so
    /// the panel's height never changes while the user types. The placeholder shows while it is empty.
    private var editorBox: some View {
        ZStack(alignment: .topLeading) {
            EzraAgentContextEditor(
                text: viewModel.agentContextText,
                isEditable: viewModel.agentContextEditorIsEditable,
                connection: viewModel.agentContextEditorConnection,
                onTextChange: { editorText in
                    viewModel.agentContextEditorTextDidChange(editorText)
                }
            )
            if viewModel.agentContextText.isEmpty {
                Text(EzraAgentContextTabText.placeholderText)
                    .font(.system(size: DS.ChatPanel.inputFontSizeInPoints))
                    .foregroundColor(DS.Colors.chatPanelTertiaryText)
                    .padding(.horizontal, DS.ChatPanel.inputHorizontalPaddingInPoints)
                    .padding(.vertical, DS.ChatPanel.inputVerticalPaddingInPoints)
                    .fixedSize(horizontal: false, vertical: true)
                    // Clicks go through to the editor under it.
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: DS.ChatPanel.contextEditorHeightInPoints)
        .background(
            RoundedRectangle(cornerRadius: DS.ChatPanel.inputCornerRadiusInPoints, style: .continuous)
                .fill(DS.Colors.chatPanelInputBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.ChatPanel.inputCornerRadiusInPoints, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.ChatPanel.inputCornerRadiusInPoints, style: .continuous)
                .stroke(DS.Colors.chatPanelDivider, lineWidth: 1)
        )
    }

    // MARK: - The row under the editor

    /// Left the count and the save mark, right "clear" (or "clear everything?" with its two answers).
    private var counterAndClearRow: some View {
        HStack(alignment: .center, spacing: DS.ChatPanel.contextSectionSpacingInPoints) {
            Text(EzraAgentContextTabText.counterText(forCharacterCount: viewModel.agentContextCharacterCount))
                .font(.system(size: DS.ChatPanel.contextCounterFontSizeInPoints).monospacedDigit())
                .foregroundColor(counterColor)
                .lineLimit(1)
                .accessibilityLabel("\(viewModel.agentContextCharacterCount) of \(EzraAgentContextLimits.maximumCharacterCount) characters")

            if let saveMark = viewModel.agentContextSaveMark {
                Text(saveMark.text)
                    .font(.system(size: DS.ChatPanel.contextCounterFontSizeInPoints, weight: .medium))
                    .foregroundColor(saveMarkColor(for: saveMark.tone))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .transition(.opacity)
            }

            Spacer(minLength: 0)

            clearControls
        }
        .padding(.leading, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
        .animation(.easeOut(duration: DS.Animation.fast), value: viewModel.agentContextSaveMark)
    }

    /// "clear" only while there is something to clear. The first click asks in place; nothing is
    /// cleared until the second.
    @ViewBuilder
    private var clearControls: some View {
        if viewModel.contextClearConfirmationIsShowing {
            HStack(spacing: DS.ChatPanel.memoryRowActionSpacingInPoints) {
                Text(EzraAgentContextTabText.clearConfirmationQuestionText)
                    .font(.system(size: DS.ChatPanel.textActionFontSizeInPoints))
                    .foregroundColor(DS.Colors.chatPanelSecondaryText)
                Button(action: { viewModel.confirmClearingContext() }) {
                    Text(EzraAgentContextTabText.clearConfirmButtonTitle)
                }
                .buttonStyle(EzraChatTextButtonStyle(isDestructive: true))
                .accessibilityLabel("confirm clearing the whole context")
                Button(action: { viewModel.cancelClearingContext() }) {
                    Text(EzraAgentContextTabText.clearCancelButtonTitle)
                }
                .buttonStyle(EzraChatTextButtonStyle())
                .accessibilityLabel("keep the context")
            }
        } else if !viewModel.agentContextText.isEmpty {
            Button(action: { viewModel.askToConfirmClearingContext() }) {
                Text(EzraAgentContextTabText.clearButtonTitle)
            }
            .buttonStyle(EzraChatTextButtonStyle(isDestructive: true))
            .accessibilityLabel("clear the context")
        }
    }

    private func warningLine(_ warningText: String) -> some View {
        Text(warningText)
            .font(.system(size: DS.ChatPanel.rowDetailFontSizeInPoints))
            .foregroundColor(DS.Colors.chatPanelPermissionMissingText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
    }

    // MARK: - Colours

    /// Quiet below 1,800 characters, amber from 1,800, red at 2,000 and over (the permission rows' amber
    /// and the panel's error red, so the panel keeps one amber and one red).
    private var counterColor: Color {
        switch EzraAgentContextTabText.counterTone(forCharacterCount: viewModel.agentContextCharacterCount) {
        case .quiet: return DS.Colors.chatPanelTertiaryText
        case .nearTheLimit: return DS.Colors.chatPanelPermissionMissingText
        case .atOrOverTheLimit: return DS.Colors.chatPanelErrorText
        }
    }

    /// "saving…" dim, "saved ✓" in the permission rows' green, "couldn't save: …" in the error red.
    private func saveMarkColor(for saveMarkTone: EzraAgentContextSaveMarkTone) -> Color {
        switch saveMarkTone {
        case .quiet: return DS.Colors.chatPanelTertiaryText
        case .success: return DS.Colors.chatPanelPermissionGrantedText
        case .failure: return DS.Colors.chatPanelErrorText
        }
    }
}
