//
//  ClickyChatPanelSettingsView.swift
//  leanring-buddy
//
//  The "settings" tab of the chat panel: the same settings as the menu bar panel (model, show
//  clicky, dictation, status pill) bound to the same state, three voice options ("speak
//  replies", "speak typed replies", "drawings stay"), a cheat sheet of the shortcuts, and the
//  status of the four permissions with an "open settings" button each.
//
//  The view holds no state of its own. It shows what the view model mirrors from the app, and
//  every change goes back through the view model to `CompanionManager`, which stores it in the
//  same `UserDefaults` keys the menu bar panel uses, so a setting changed in either place shows
//  in the other. The panel gives this view its scrolling and its height.
//

import SwiftUI

struct ClickyChatPanelSettingsContentView: View {
    @ObservedObject var viewModel: ClickyChatPanelViewModel

    private var settings: ClickyPanelSettingsSnapshot {
        viewModel.panelSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.ChatPanel.tabSectionSpacingInPoints) {
            generalSection
            voiceSection
            filesSection
            shortcutsSection
            permissionsSection
        }
    }

    // MARK: - General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("GENERAL")

            settingRow(symbolName: "sparkles", title: "model", hint: nil) {
                ClickyChatChoiceRow(
                    choices: ClickyPanelModelOption.all.map { (title: $0.title, value: $0.modelIdentifier) },
                    selectedValue: settings.selectedModelIdentifier,
                    onSelect: { viewModel.applyPanelSettingChange(.selectedModel($0)) }
                )
            }
            settingRow(symbolName: "cursorarrow", title: "show clicky", hint: "the blue cursor") {
                settingSwitch(isOn: settings.isClickyCursorEnabled) { viewModel.applyPanelSettingChange(.clickyCursorEnabled($0)) }
            }
            settingRow(symbolName: "text.cursor", title: "dictation", hint: "hold fn + option") {
                settingSwitch(isOn: settings.isDictationEnabled) { viewModel.applyPanelSettingChange(.dictationEnabled($0)) }
            }
            settingRow(symbolName: "capsule", title: "status pill", hint: "shows what clicky is doing") {
                settingSwitch(isOn: settings.isStatusPillEnabled) { viewModel.applyPanelSettingChange(.statusPillEnabled($0)) }
            }
        }
    }

    // MARK: - Voice

    private var voiceSection: some View {
        let lifetimes = ClickyDrawingLifetimes.lifetimes(for: settings.drawingLifetimeChoice)
        return VStack(alignment: .leading, spacing: 0) {
            sectionTitle("VOICE")

            settingRow(
                symbolName: "speaker.wave.2",
                title: "speak replies",
                hint: settings.isSpeakingRepliesEnabled ? "replies to your voice are read aloud" : "replies show as text in this panel"
            ) {
                settingSwitch(isOn: settings.isSpeakingRepliesEnabled) { viewModel.applyPanelSettingChange(.speakingRepliesEnabled($0)) }
            }
            settingRow(
                symbolName: "keyboard",
                title: "speak typed replies",
                hint: settings.isSpeakingRepliesEnabled ? "also read aloud the replies to what you type" : "needs speak replies on"
            ) {
                settingSwitch(isOn: settings.isSpeakingTypedRepliesEnabled) { viewModel.applyPanelSettingChange(.speakingTypedRepliesEnabled($0)) }
            }
            .disabled(!settings.isSpeakingRepliesEnabled)
            .opacity(settings.isSpeakingRepliesEnabled ? 1 : DS.ChatPanel.disabledRowOpacity)

            settingRow(
                symbolName: "pencil.and.scribble",
                title: "drawings stay",
                hint: "marks \(Self.secondsText(lifetimes.secondsMarksStayAfterReplyEnds)) · card \(Self.secondsText(lifetimes.secondsExplanationCardStaysAfterReplyEnds)) · scene \(Self.secondsText(lifetimes.secondsSceneStaysAfterReplyEnds))"
            ) {
                ClickyChatChoiceRow(
                    choices: ClickyDrawingLifetimeChoice.allCases.map { (title: $0.title, value: $0) },
                    selectedValue: settings.drawingLifetimeChoice,
                    onSelect: { viewModel.applyPanelSettingChange(.drawingLifetime($0)) }
                )
            }
        }
    }

    /// "12 s", "6 s", "12.5 s": a whole number of seconds without a decimal.
    private static func secondsText(_ seconds: TimeInterval) -> String {
        let isWholeNumber = seconds == seconds.rounded()
        return (isWholeNumber ? String(format: "%.0f", seconds) : String(format: "%.1f", seconds)) + " s"
    }

    // MARK: - Files (round 17)

    /// The folders Clicky may read and change. With none, Clicky touches no file at all and every
    /// request is what it always was, so this section is also the switch of the whole feature.
    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("FILES")

            Text("folders clicky may edit. it only reads and changes files inside them. every change is shown first and written after you press return or say yes. backups let you undo, and deleted files go to the trash.")
                .font(.system(size: DS.ChatPanel.rowDetailFontSizeInPoints))
                .foregroundColor(DS.Colors.chatPanelTertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
                .padding(.bottom, 6)

            if viewModel.editableFolderRows.isEmpty {
                Text("no folder yet, so clicky can't touch any file.")
                    .font(.system(size: DS.ChatPanel.messageFontSizeInPoints))
                    .foregroundColor(DS.Colors.chatPanelSecondaryText)
                    .padding(.horizontal, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
                    .padding(.vertical, DS.ChatPanel.folderRowVerticalPaddingInPoints)
            } else {
                ForEach(viewModel.editableFolderRows) { folderRow in
                    ClickyEditableFolderRowView(viewModel: viewModel, folderRow: folderRow)
                }
            }

            HStack(spacing: 8) {
                Button(action: { viewModel.requestAddingEditableFolder() }) {
                    Label("add folder…", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(ClickyChatTextButtonStyle(isProminent: true))
                .accessibilityLabel("add a folder clicky may edit")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
            .padding(.top, 6)

            if let editableFolderMessage = viewModel.editableFolderMessage {
                Text(editableFolderMessage)
                    .font(.system(size: DS.ChatPanel.rowDetailFontSizeInPoints))
                    .foregroundColor(DS.Colors.chatPanelErrorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
                    .padding(.top, 6)
            }
        }
    }

    // MARK: - Shortcuts

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("SHORTCUTS")
            ForEach(ClickyShortcutCheatSheet.entries, id: \.keys) { shortcutEntry in
                HStack(spacing: 10) {
                    Text(shortcutEntry.keys)
                        .font(.system(size: DS.ChatPanel.keycapFontSizeInPoints, weight: .medium, design: .rounded))
                        .foregroundColor(DS.Colors.chatPanelPrimaryText)
                        .padding(.horizontal, DS.ChatPanel.keycapHorizontalPaddingInPoints)
                        .padding(.vertical, DS.ChatPanel.keycapVerticalPaddingInPoints)
                        .background(
                            RoundedRectangle(cornerRadius: DS.ChatPanel.keycapCornerRadiusInPoints, style: .continuous)
                                .fill(DS.Colors.chatPanelKeycapBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.ChatPanel.keycapCornerRadiusInPoints, style: .continuous)
                                .stroke(DS.Colors.chatPanelKeycapBorder, lineWidth: 1)
                        )
                        .frame(width: DS.ChatPanel.keycapColumnWidthInPoints, alignment: .leading)
                    Text(shortcutEntry.action)
                        .font(.system(size: DS.ChatPanel.messageFontSizeInPoints))
                        .foregroundColor(DS.Colors.chatPanelSecondaryText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
                .padding(.vertical, DS.ChatPanel.settingsRowVerticalPaddingInPoints - 1)
            }
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("PERMISSIONS")
            ForEach(ClickyPermissionKind.allCases, id: \.self) { permissionKind in
                let isGranted = viewModel.isPermissionGranted(permissionKind)
                HStack(spacing: 8) {
                    Image(systemName: permissionKind.symbolName)
                        .font(.system(size: DS.ChatPanel.iconFontSizeInPoints, weight: .medium))
                        .foregroundColor(DS.Colors.chatPanelTertiaryText)
                        .frame(width: DS.ChatPanel.settingsRowIconWidthInPoints)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(permissionKind.title)
                            .font(.system(size: DS.ChatPanel.rowTitleFontSizeInPoints, weight: .medium))
                            .foregroundColor(DS.Colors.chatPanelPrimaryText)
                        Text(permissionKind.purpose)
                            .font(.system(size: DS.ChatPanel.rowDetailFontSizeInPoints))
                            .foregroundColor(DS.Colors.chatPanelTertiaryText)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 5) {
                        Circle()
                            .fill(isGranted ? DS.Colors.chatPanelPermissionGrantedText : DS.Colors.chatPanelPermissionMissingText)
                            .frame(width: DS.ChatPanel.permissionDotDiameterInPoints, height: DS.ChatPanel.permissionDotDiameterInPoints)
                        Text(isGranted ? "granted" : "not granted")
                            .font(.system(size: DS.ChatPanel.rowDetailFontSizeInPoints, weight: .medium))
                            .foregroundColor(isGranted ? DS.Colors.chatPanelPermissionGrantedText : DS.Colors.chatPanelPermissionMissingText)
                    }

                    Button(action: { viewModel.openPermissionSettings(for: permissionKind) }) {
                        Text("open settings")
                    }
                    .buttonStyle(ClickyChatTextButtonStyle())
                    .accessibilityLabel("open the \(permissionKind.title) settings")
                }
                .padding(.horizontal, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
                .padding(.vertical, DS.ChatPanel.settingsRowVerticalPaddingInPoints)
            }
        }
    }

    // MARK: - Pieces

    private func sectionTitle(_ titleText: String) -> some View {
        Text(titleText)
            .font(.system(size: DS.ChatPanel.sectionTitleFontSizeInPoints, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(DS.Colors.chatPanelTertiaryText)
            .padding(.horizontal, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
            .padding(.bottom, DS.ChatPanel.tabSectionTitleBottomPaddingInPoints)
    }

    /// An icon, a name, an optional hint under it, and a control on the right.
    private func settingRow<Control: View>(
        symbolName: String,
        title: String,
        hint: String?,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .font(.system(size: DS.ChatPanel.iconFontSizeInPoints, weight: .medium))
                .foregroundColor(DS.Colors.chatPanelTertiaryText)
                .frame(width: DS.ChatPanel.settingsRowIconWidthInPoints)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: DS.ChatPanel.rowTitleFontSizeInPoints, weight: .medium))
                    .foregroundColor(DS.Colors.chatPanelPrimaryText)
                if let hint {
                    Text(hint)
                        .font(.system(size: DS.ChatPanel.rowDetailFontSizeInPoints))
                        .foregroundColor(DS.Colors.chatPanelTertiaryText)
                }
            }

            Spacer(minLength: 8)

            control()
        }
        .padding(.horizontal, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
        .padding(.vertical, DS.ChatPanel.settingsRowVerticalPaddingInPoints)
    }

    /// An on/off switch. A clickable control, so it lights up under the pointer and shows the
    /// pointing hand.
    private func settingSwitch(isOn: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        Toggle("", isOn: Binding(get: { isOn }, set: onChange))
            .toggleStyle(ClickyChatSwitchToggleStyle())
            .labelsHidden()
    }
}

// MARK: - The switch

/// The panel's own on/off switch: a blue track with the knob on the right when on, a dark track
/// with the knob on the left when off. Drawn here because the system switch shows no colour in a
/// window that is not the active one (this panel never activates Clicky), so on and off would
/// differ only by the side the knob is on.
struct ClickyChatSwitchToggleStyle: ToggleStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? DS.Colors.chatPanelSwitchOnTrack : DS.Colors.chatPanelSwitchOffTrack)
                    .frame(width: DS.ChatPanel.switchTrackWidthInPoints, height: DS.ChatPanel.switchTrackHeightInPoints)
                Circle()
                    .fill(DS.Colors.chatPanelSwitchKnob)
                    .frame(
                        width: DS.ChatPanel.switchTrackHeightInPoints - 2 * DS.ChatPanel.switchKnobInsetInPoints,
                        height: DS.ChatPanel.switchTrackHeightInPoints - 2 * DS.ChatPanel.switchKnobInsetInPoints
                    )
                    .padding(DS.ChatPanel.switchKnobInsetInPoints)
            }
            .brightness(isHovered ? 0.12 : 0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isOn)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
        .accessibilityValue(configuration.isOn ? "on" : "off")
    }
}

// MARK: - A row of choices

/// "sonnet | opus", "short | normal | long": a few words in a track, the chosen one lit. Every
/// choice lights up under the pointer and shows the pointing hand.
struct ClickyChatChoiceRow<Value: Hashable>: View {
    let choices: [(title: String, value: Value)]
    let selectedValue: Value
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                Button(action: { onSelect(choice.value) }) {
                    Text(choice.title)
                }
                .buttonStyle(ClickyChatChoiceButtonStyle(isSelected: choice.value == selectedValue))
                .accessibilityLabel(choice.title)
                .accessibilityAddTraits(choice.value == selectedValue ? .isSelected : [])
            }
        }
        .padding(DS.ChatPanel.choiceTrackPaddingInPoints)
        .background(
            RoundedRectangle(cornerRadius: DS.ChatPanel.choiceCornerRadiusInPoints + DS.ChatPanel.choiceTrackPaddingInPoints, style: .continuous)
                .fill(DS.Colors.chatPanelChoiceTrackBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.ChatPanel.choiceCornerRadiusInPoints + DS.ChatPanel.choiceTrackPaddingInPoints, style: .continuous)
                .stroke(DS.Colors.chatPanelDivider, lineWidth: 1)
        )
    }
}

private struct ClickyChatChoiceButtonStyle: ButtonStyle {
    let isSelected: Bool

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: DS.ChatPanel.choiceFontSizeInPoints, weight: .medium))
            .foregroundColor(isSelected ? DS.Colors.chatPanelPrimaryText : (isHovered ? DS.Colors.chatPanelPrimaryText : DS.Colors.chatPanelSecondaryText))
            .padding(.horizontal, DS.ChatPanel.choiceHorizontalPaddingInPoints)
            .padding(.vertical, DS.ChatPanel.choiceVerticalPaddingInPoints)
            .background(
                RoundedRectangle(cornerRadius: DS.ChatPanel.choiceCornerRadiusInPoints, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.ChatPanel.choiceCornerRadiusInPoints, style: .continuous))
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = $0 }
            .pointerCursor()
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isSelected { return DS.Colors.chatPanelChoiceSelectedBackground }
        if isPressed { return DS.Colors.surface3 }
        return isHovered ? DS.Colors.chatPanelRowHoverBackground : Color.clear
    }
}


// MARK: - One folder of the "files" section

/// A folder's name and its shortened path, and a remove button that asks "remove this?" in place
/// (never an alert), like the memory tab's delete.
private struct ClickyEditableFolderRowView: View {
    @ObservedObject var viewModel: ClickyChatPanelViewModel
    let folderRow: ClickyEditableFolderRow

    @State private var isHovered = false

    private var isAskingToConfirmRemoval: Bool {
        viewModel.editableFolderAwaitingRemovalConfirmation == folderRow.path
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: DS.ChatPanel.iconFontSizeInPoints, weight: .medium))
                .foregroundColor(DS.Colors.chatPanelTertiaryText)
                .frame(width: DS.ChatPanel.settingsRowIconWidthInPoints)

            VStack(alignment: .leading, spacing: 1) {
                Text(folderRow.name)
                    .font(.system(size: DS.ChatPanel.rowTitleFontSizeInPoints, weight: .medium))
                    .foregroundColor(DS.Colors.chatPanelPrimaryText)
                    .lineLimit(1)
                Text(folderRow.shortenedPath)
                    .font(.system(size: DS.ChatPanel.rowDetailFontSizeInPoints))
                    .foregroundColor(DS.Colors.chatPanelTertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            removeControls
        }
        .padding(.horizontal, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
        .padding(.vertical, DS.ChatPanel.folderRowVerticalPaddingInPoints)
        .background(
            RoundedRectangle(cornerRadius: DS.ChatPanel.listRowCornerRadiusInPoints, style: .continuous)
                .fill(isHovered || isAskingToConfirmRemoval ? DS.Colors.chatPanelRowHoverBackground : Color.clear)
        )
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var removeControls: some View {
        if isAskingToConfirmRemoval {
            HStack(spacing: DS.ChatPanel.memoryRowActionSpacingInPoints) {
                Text("remove this?")
                    .font(.system(size: DS.ChatPanel.textActionFontSizeInPoints))
                    .foregroundColor(DS.Colors.chatPanelSecondaryText)
                Button(action: { viewModel.confirmRemovingEditableFolder(path: folderRow.path) }) {
                    Text("remove")
                }
                .buttonStyle(ClickyChatTextButtonStyle(isDestructive: true))
                .accessibilityLabel("confirm removing this folder")
                Button(action: { viewModel.cancelEditableFolderRemovalConfirmation() }) {
                    Text("cancel")
                }
                .buttonStyle(ClickyChatTextButtonStyle())
            }
        } else {
            Button(action: { viewModel.askToConfirmRemovingEditableFolder(path: folderRow.path) }) {
                Text("remove")
            }
            .buttonStyle(ClickyChatTextButtonStyle(isDestructive: true))
            .accessibilityLabel("remove this folder")
        }
    }
}
