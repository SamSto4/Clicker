//
//  EzraChatPanelSettingsView.swift
//  leanring-buddy
//
//  The "settings" tab of the chat panel: the same settings as the menu bar panel (model, show
//  ezra, dictation, status pill) bound to the same state, the cursor's look (round 20: a live
//  preview, colour, shape, size and glow), the voice options ("speak replies", "speak typed
//  replies", "drawings stay", and since round 18 "follow-up listening"), the "actions" switch with
//  the persona (name, style, "call me"), the folders Ezra may edit, a cheat sheet of the
//  shortcuts, and the status of the permissions (reminders joined in round 18) with an "open
//  settings" button each.
//
//  The view holds no state of its own. It shows what the view model mirrors from the app, and
//  every change goes back through the view model to `CompanionManager`, which stores it in the
//  same `UserDefaults` keys the menu bar panel uses, so a setting changed in either place shows
//  in the other. The panel gives this view its scrolling and its height.
//

import SwiftUI

struct EzraChatPanelSettingsContentView: View {
    @ObservedObject var viewModel: EzraChatPanelViewModel

    private var settings: EzraPanelSettingsSnapshot {
        viewModel.panelSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.ChatPanel.tabSectionSpacingInPoints) {
            generalSection
            lookSection
            voiceSection
            actionsSection
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
                EzraChatChoiceRow(
                    choices: EzraPanelModelOption.all.map { (title: $0.title, value: $0.modelIdentifier) },
                    selectedValue: settings.selectedModelIdentifier,
                    onSelect: { viewModel.applyPanelSettingChange(.selectedModel($0)) }
                )
            }
            settingRow(symbolName: "cursorarrow", title: "show ezra", hint: "the cursor (its look is below)") {
                settingSwitch(isOn: settings.isEzraCursorEnabled) { viewModel.applyPanelSettingChange(.ezraCursorEnabled($0)) }
            }
            settingRow(symbolName: "text.cursor", title: "dictation", hint: "hold fn + option") {
                settingSwitch(isOn: settings.isDictationEnabled) { viewModel.applyPanelSettingChange(.dictationEnabled($0)) }
            }
            settingRow(symbolName: "capsule", title: "status pill", hint: "shows what ezra is doing") {
                settingSwitch(isOn: settings.isStatusPillEnabled) { viewModel.applyPanelSettingChange(.statusPillEnabled($0)) }
            }
        }
    }

    // MARK: - Look (round 20, the cursor studio)

    /// The cursor's colour, shape, size and glow, with a live preview. Right after GENERAL because
    /// it is about the cursor that "show ezra" switches. A change shows on the real cursor at once
    /// (the overlay watches the same state); nothing here reaches the model or a log.
    private var lookSection: some View {
        let cursorStyle = settings.cursorStyle
        let colourEntryHint = viewModel.cursorColourEntryHintText
        return VStack(alignment: .leading, spacing: 0) {
            sectionTitle("LOOK")

            settingRow(symbolName: "eye", title: "preview", hint: "on a dark and a light page") {
                EzraCursorStylePreview(cursorStyle: cursorStyle)
            }

            settingRow(
                symbolName: "paintpalette",
                title: "colour",
                hint: colourEntryHint ?? (EzraCursorColour.paletteName(forHex: cursorStyle.colourHex) ?? "your own colour"),
                hintColor: colourEntryHint == nil ? DS.Colors.chatPanelTertiaryText : DS.Colors.chatPanelErrorText
            ) {
                EzraChatSettingsTextField(
                    placeholderText: EzraCursorStyle.defaultColourHex,
                    committedText: cursorStyle.colourHex,
                    onCommit: { viewModel.submitCursorColourText($0) },
                    // A colour is shown as it is stored ("#abc" becomes "#AABBCC"); anything else puts
                    // the stored colour back.
                    shownTextAfterCommit: { enteredText in EzraCursorColour.parse(enteredText) ?? cursorStyle.colourHex },
                    fieldWidthInPoints: DS.ChatPanel.cursorColourHexFieldWidthInPoints
                )
            }
            colourSwatchRow(chosenColourHex: cursorStyle.colourHex)

            // The five shape words are the widest choice row of the tab: it keeps its natural width
            // (no word is ever broken) and the hint beside it wraps instead.
            settingRow(symbolName: "location.north", title: "shape", hint: "pointed shapes turn toward where ezra flies") {
                EzraChatChoiceRow(
                    choices: EzraCursorShape.allCases.map { (title: $0.title, value: $0) },
                    selectedValue: cursorStyle.shape,
                    onSelect: { viewModel.applyPanelSettingChange(.cursorShape($0)) }
                )
                .fixedSize()
            }
            settingRow(symbolName: "arrow.up.left.and.arrow.down.right", title: "size", hint: nil) {
                EzraChatChoiceRow(
                    choices: EzraCursorSize.allCases.map { (title: $0.title, value: $0) },
                    selectedValue: cursorStyle.size,
                    onSelect: { viewModel.applyPanelSettingChange(.cursorSize($0)) }
                )
                .fixedSize()
            }
            settingRow(symbolName: "sun.max", title: "glow", hint: nil) {
                EzraChatChoiceRow(
                    choices: EzraCursorGlow.allCases.map { (title: $0.title, value: $0) },
                    selectedValue: cursorStyle.glow,
                    onSelect: { viewModel.applyPanelSettingChange(.cursorGlow($0)) }
                )
                .fixedSize()
            }

            // Only when there is something to reset.
            if !cursorStyle.isDefault {
                HStack(spacing: 0) {
                    Button(action: { viewModel.resetCursorLook() }) {
                        Label("reset look", systemImage: "arrow.uturn.backward")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(EzraChatTextButtonStyle())
                    .accessibilityLabel("reset the cursor to the blue triangle")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
                .padding(.top, 4)
            }
        }
    }

    /// The ten palette colours as round swatches, under the "colour" row and indented to its title.
    private func colourSwatchRow(chosenColourHex: String) -> some View {
        HStack(spacing: DS.ChatPanel.colourSwatchSpacingInPoints) {
            ForEach(EzraCursorColour.palette, id: \.hex) { paletteEntry in
                EzraCursorColourSwatchButton(
                    paletteEntry: paletteEntry,
                    isChosen: paletteEntry.hex == chosenColourHex,
                    onChoose: { viewModel.applyPanelSettingChange(.cursorColourHex(paletteEntry.hex)) }
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, DS.ChatPanel.memoryRowHorizontalPaddingInPoints + DS.ChatPanel.settingsRowIconWidthInPoints + 8)
        .padding(.trailing, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
        .padding(.bottom, DS.ChatPanel.settingsRowVerticalPaddingInPoints)
    }

    // MARK: - Voice

    private var voiceSection: some View {
        let lifetimes = EzraDrawingLifetimes.lifetimes(for: settings.drawingLifetimeChoice)
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

            voicePicker

            settingRow(
                symbolName: "gauge.with.dots.needle.50percent",
                title: "speed",
                hint: EzraVoiceSettings.speedHint(forPercent: settings.speechSpeedPercent)
            ) {
                EzraChatChoiceRow(
                    choices: EzraVoiceSettings.speedSteps.map { (title: EzraVoiceSettings.speedStepTitle(forPercent: $0), value: $0) },
                    selectedValue: EzraVoiceSettings.speedStep(forPercent: settings.speechSpeedPercent),
                    onSelect: { viewModel.applyPanelSettingChange(.speechSpeedPercent($0)) }
                )
                .fixedSize()
            }

            settingRow(
                symbolName: "pencil.and.scribble",
                title: "drawings stay",
                hint: "marks \(Self.secondsText(lifetimes.secondsMarksStayAfterReplyEnds)) · card \(Self.secondsText(lifetimes.secondsExplanationCardStaysAfterReplyEnds)) · scene \(Self.secondsText(lifetimes.secondsSceneStaysAfterReplyEnds))"
            ) {
                EzraChatChoiceRow(
                    choices: EzraDrawingLifetimeChoice.allCases.map { (title: $0.title, value: $0) },
                    selectedValue: settings.drawingLifetimeChoice,
                    onSelect: { viewModel.applyPanelSettingChange(.drawingLifetime($0)) }
                )
            }

            settingRow(
                symbolName: "ear",
                title: "follow-up listening",
                hint: "after a spoken reply, listens \(Int(EzraFollowUpListeningConstants.noSpeechGiveUpSeconds)) seconds for more"
            ) {
                settingSwitch(isOn: settings.isFollowUpListeningEnabled) { viewModel.applyPanelSettingChange(.followUpListeningEnabled($0)) }
            }
        }
    }

    // MARK: - The voice picker (round 20)

    /// "voice": which ElevenLabs voice of the account speaks, with a sample of each. The list comes
    /// from the Worker when the tab opens (the kept copy shows first); choosing the Worker's default
    /// voice stores nothing, so the /tts body is then exactly today's.
    private var voicePicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingRow(symbolName: "person.wave.2", title: "voice", hint: viewModel.voicePickerHintText) {
                Button(action: { viewModel.refreshVoiceList() }) {
                    Label(viewModel.voiceListFetchState == .loading ? "loading…" : "refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(EzraChatTextButtonStyle())
                .disabled(viewModel.voiceListFetchState == .loading)
                .accessibilityLabel("load the voices of the account again")
            }

            // Why the voice changed back, or why no new list came. Nothing is spoken about either.
            ForEach([viewModel.voicePickerNoticeText, viewModel.voiceListLoadNoticeText].compactMap { $0 }, id: \.self) { noticeText in
                Text(noticeText)
                    .font(.system(size: DS.ChatPanel.rowDetailFontSizeInPoints))
                    .foregroundColor(DS.Colors.chatPanelErrorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, DS.ChatPanel.memoryRowHorizontalPaddingInPoints + DS.ChatPanel.voiceListLeadingIndentInPoints)
                    .padding(.trailing, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
                    .padding(.bottom, 4)
            }

            ForEach(viewModel.voiceListRows) { voicePickerRow in
                EzraVoicePickerRowView(viewModel: viewModel, voicePickerRow: voicePickerRow)
            }
        }
    }

    // MARK: - Actions and persona (round 18)

    /// The switch for everything Ezra can do for the user (open apps, links and files, timers,
    /// reminders, shortcuts), and how it sounds: its name, its style and what it calls the user.
    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("ACTIONS")

            settingRow(
                symbolName: "bolt",
                title: "actions",
                hint: "open apps, links and files, timers, reminders and shortcuts when you ask"
            ) {
                settingSwitch(isOn: settings.isActionsEnabled) { viewModel.applyPanelSettingChange(.actionsEnabled($0)) }
            }

            // Round 19: plain commands ("open safari", "set a timer for 10 minutes") with no model call.
            // They are actions, so the row is dimmed while actions are off.
            settingRow(
                symbolName: "hare",
                title: "quick commands",
                hint: settings.isActionsEnabled ? "open apps and set timers without asking the ai" : "needs actions on"
            ) {
                settingSwitch(isOn: settings.isQuickCommandsEnabled) { viewModel.applyPanelSettingChange(.quickCommandsEnabled($0)) }
            }
            .disabled(!settings.isActionsEnabled)
            .opacity(settings.isActionsEnabled ? 1 : DS.ChatPanel.disabledRowOpacity)

            settingRow(symbolName: "person.text.rectangle", title: "assistant name", hint: "empty means ezra") {
                EzraChatSettingsTextField(
                    placeholderText: "ezra",
                    committedText: settings.personaAssistantName,
                    onCommit: { viewModel.applyPanelSettingChange(.personaAssistantName($0)) }
                )
            }
            settingRow(symbolName: "theatermasks", title: "style", hint: settings.personaStyle.promptText == nil ? "how ezra is today" : nil) {
                EzraChatChoiceRow(
                    choices: EzraPersonaStyle.allCases.map { (title: $0.title, value: $0) },
                    selectedValue: settings.personaStyle,
                    onSelect: { viewModel.applyPanelSettingChange(.personaStyle($0)) }
                )
            }
            settingRow(symbolName: "quote.bubble", title: "call me", hint: "now and then, not in every sentence") {
                EzraChatSettingsTextField(
                    placeholderText: "nothing",
                    committedText: settings.personaUserAddress,
                    onCommit: { viewModel.applyPanelSettingChange(.personaUserAddress($0)) }
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

    /// The folders Ezra may read and change. With none, Ezra touches no file at all and every
    /// request is what it always was, so this section is also the switch of the whole feature.
    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("FILES")

            Text("folders ezra may edit. it only reads and changes files inside them. every change is shown first and written after you press return or say yes. backups let you undo, and deleted files go to the trash.")
                .font(.system(size: DS.ChatPanel.rowDetailFontSizeInPoints))
                .foregroundColor(DS.Colors.chatPanelTertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
                .padding(.bottom, 6)

            if viewModel.editableFolderRows.isEmpty {
                Text("no folder yet, so ezra can't touch any file.")
                    .font(.system(size: DS.ChatPanel.messageFontSizeInPoints))
                    .foregroundColor(DS.Colors.chatPanelSecondaryText)
                    .padding(.horizontal, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
                    .padding(.vertical, DS.ChatPanel.folderRowVerticalPaddingInPoints)
            } else {
                ForEach(viewModel.editableFolderRows) { folderRow in
                    EzraEditableFolderRowView(viewModel: viewModel, folderRow: folderRow)
                }
            }

            HStack(spacing: 8) {
                Button(action: { viewModel.requestAddingEditableFolder() }) {
                    Label("add folder…", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(EzraChatTextButtonStyle(isProminent: true))
                .accessibilityLabel("add a folder ezra may edit")
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
            ForEach(EzraShortcutCheatSheet.entries, id: \.keys) { shortcutEntry in
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
            ForEach(EzraPermissionKind.allCases, id: \.self) { permissionKind in
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
                    .buttonStyle(EzraChatTextButtonStyle())
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

    /// An icon, a name, an optional hint under it, and a control on the right. `hintColor` lets a
    /// hint read as a warning ("use #RRGGBB", round 20); it is the faint hint colour otherwise.
    private func settingRow<Control: View>(
        symbolName: String,
        title: String,
        hint: String?,
        hintColor: Color = DS.Colors.chatPanelTertiaryText,
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
                        .foregroundColor(hintColor)
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
            .toggleStyle(EzraChatSwitchToggleStyle())
            .labelsHidden()
    }
}

// MARK: - The switch

/// The panel's own on/off switch: a blue track with the knob on the right when on, a dark track
/// with the knob on the left when off. Drawn here because the system switch shows no colour in a
/// window that is not the active one (this panel never activates Ezra), so on and off would
/// differ only by the side the knob is on.
struct EzraChatSwitchToggleStyle: ToggleStyle {
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
struct EzraChatChoiceRow<Value: Hashable>: View {
    let choices: [(title: String, value: Value)]
    let selectedValue: Value
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                Button(action: { onSelect(choice.value) }) {
                    Text(choice.title)
                }
                .buttonStyle(EzraChatChoiceButtonStyle(isSelected: choice.value == selectedValue))
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

private struct EzraChatChoiceButtonStyle: ButtonStyle {
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
private struct EzraEditableFolderRowView: View {
    @ObservedObject var viewModel: EzraChatPanelViewModel
    let folderRow: EzraEditableFolderRow

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
                .buttonStyle(EzraChatTextButtonStyle(isDestructive: true))
                .accessibilityLabel("confirm removing this folder")
                Button(action: { viewModel.cancelEditableFolderRemovalConfirmation() }) {
                    Text("cancel")
                }
                .buttonStyle(EzraChatTextButtonStyle())
            }
        } else {
            Button(action: { viewModel.askToConfirmRemovingEditableFolder(path: folderRow.path) }) {
                Text("remove")
            }
            .buttonStyle(EzraChatTextButtonStyle(isDestructive: true))
            .accessibilityLabel("remove this folder")
        }
    }
}


// MARK: - A one-line text field

/// A single-line field for a short value. It commits on Return and when it loses the keyboard, and
/// shows what the app stored (cleaned) when it is not being edited. The panel is a key-capable
/// window that never activates Ezra, so typing reaches the field once it has been clicked, like
/// the "ask ezra" field. Hover shows the text cursor and a brighter edge.
struct EzraChatSettingsTextField: View {
    let placeholderText: String
    let committedText: String
    let onCommit: (String) -> Void
    /// What the field shows right after a commit: the text as the app will store it. The persona
    /// fields show the cleaned name (the default); the colour field (round 20) shows "#RRGGBB", or
    /// the stored colour again when what was entered is not a colour.
    var shownTextAfterCommit: (String) -> String = { EzraPersona.cleanedName($0) }
    var fieldWidthInPoints: CGFloat = DS.ChatPanel.settingsTextFieldWidthInPoints

    @State private var draftText = ""
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholderText, text: $draftText)
            .textFieldStyle(.plain)
            .font(.system(size: DS.ChatPanel.settingsTextFieldFontSizeInPoints))
            .foregroundColor(DS.Colors.chatPanelPrimaryText)
            .focused($isFocused)
            .onSubmit { commitDraft() }
            .padding(.horizontal, DS.ChatPanel.settingsTextFieldHorizontalPaddingInPoints)
            .padding(.vertical, DS.ChatPanel.settingsTextFieldVerticalPaddingInPoints)
            .frame(width: fieldWidthInPoints)
            .background(
                RoundedRectangle(cornerRadius: DS.ChatPanel.settingsTextFieldCornerRadiusInPoints, style: .continuous)
                    .fill(DS.Colors.chatPanelChoiceTrackBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.ChatPanel.settingsTextFieldCornerRadiusInPoints, style: .continuous)
                    .stroke(isFocused ? DS.Colors.chatPanelAskingAccent : (isHovered ? DS.Colors.chatPanelTertiaryText : DS.Colors.chatPanelDivider), lineWidth: 1)
            )
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onAppear { draftText = committedText }
            .onChange(of: committedText) { _, newCommittedText in
                // What the app stored (cleaned) replaces the draft, unless the user is typing.
                if !isFocused { draftText = newCommittedText }
            }
            .onChange(of: isFocused) { _, isNowFocused in
                if !isNowFocused { commitDraft() }
            }
            .accessibilityLabel(placeholderText)
    }

    private func commitDraft() {
        guard draftText != committedText else { return }
        onCommit(draftText)
        // Shown again as the app stores it (a persona name: brackets and quotes taken out, cut to 24
        // characters; a colour: "#RRGGBB", or the stored colour for text that is not one).
        draftText = shownTextAfterCommit(draftText)
    }
}

// MARK: - The voice picker's pieces (round 20)

/// One voice of the picker: a mark (filled when chosen), the name with a "default" tag on the
/// Worker's default voice, the labels small and grey, and a sample button at the right. Clicking the
/// row chooses the voice. The row lights up under the pointer; both buttons show the pointing hand.
private struct EzraVoicePickerRowView: View {
    @ObservedObject var viewModel: EzraChatPanelViewModel
    let voicePickerRow: EzraVoicePickerRow

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { viewModel.chooseVoice(voicePickerRow) }) {
                HStack(spacing: 8) {
                    Image(systemName: voicePickerRow.isChosen ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: DS.ChatPanel.iconFontSizeInPoints, weight: .medium))
                        .foregroundColor(voicePickerRow.isChosen ? DS.Colors.chatPanelVoiceChosenMark : DS.Colors.chatPanelTertiaryText)
                        .frame(width: DS.ChatPanel.voiceRowMarkWidthInPoints)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(voicePickerRow.title)
                                .font(.system(size: DS.ChatPanel.rowTitleFontSizeInPoints, weight: .medium))
                                .foregroundColor(DS.Colors.chatPanelPrimaryText)
                                .lineLimit(1)
                            if voicePickerRow.isWorkerDefaultVoice {
                                Text("default")
                                    .font(.system(size: DS.ChatPanel.voiceDefaultTagFontSizeInPoints, weight: .semibold))
                                    .foregroundColor(DS.Colors.chatPanelVoiceDefaultTagText)
                                    .padding(.horizontal, DS.ChatPanel.voiceDefaultTagHorizontalPaddingInPoints)
                                    .padding(.vertical, DS.ChatPanel.voiceDefaultTagVerticalPaddingInPoints)
                                    .background(
                                        RoundedRectangle(cornerRadius: DS.ChatPanel.voiceDefaultTagCornerRadiusInPoints, style: .continuous)
                                            .fill(DS.Colors.chatPanelVoiceDefaultTagBackground)
                                    )
                            }
                        }
                        if !voicePickerRow.subtitle.isEmpty {
                            Text(voicePickerRow.subtitle)
                                .font(.system(size: DS.ChatPanel.rowDetailFontSizeInPoints))
                                .foregroundColor(DS.Colors.chatPanelTertiaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel(voicePickerRow.isWorkerDefaultVoice ? "\(voicePickerRow.title), the worker's default voice" : voicePickerRow.title)
            .accessibilityAddTraits(voicePickerRow.isChosen ? .isSelected : [])

            EzraVoiceSampleButton(
                rowState: viewModel.samplePlaybackState(forVoiceRowIdentifier: voicePickerRow.id),
                voiceTitle: voicePickerRow.title,
                onPress: { viewModel.toggleVoiceSample(for: voicePickerRow) }
            )
        }
        .padding(.leading, DS.ChatPanel.memoryRowHorizontalPaddingInPoints + DS.ChatPanel.voiceListLeadingIndentInPoints)
        .padding(.trailing, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
        .padding(.vertical, DS.ChatPanel.voiceRowVerticalPaddingInPoints)
        .background(
            RoundedRectangle(cornerRadius: DS.ChatPanel.listRowCornerRadiusInPoints, style: .continuous)
                .fill(isHovered ? DS.Colors.chatPanelRowHoverBackground : Color.clear)
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
    }
}

/// A row's sample button: a play symbol, a small spinner while the sample is fetched, a stop symbol
/// while it plays. It brightens under the pointer and shows the pointing hand.
private struct EzraVoiceSampleButton: View {
    let rowState: EzraVoiceSampleRowState
    let voiceTitle: String
    let onPress: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onPress) {
            ZStack {
                switch rowState {
                case .idle:
                    Image(systemName: "play.circle")
                        .font(.system(size: DS.ChatPanel.voiceSampleSymbolFontSizeInPoints, weight: .regular))
                        .foregroundColor(isHovered ? DS.Colors.chatPanelPrimaryText : DS.Colors.chatPanelSecondaryText)
                case .loading:
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                case .playing:
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: DS.ChatPanel.voiceSampleSymbolFontSizeInPoints, weight: .regular))
                        .foregroundColor(DS.Colors.chatPanelVoiceChosenMark)
                }
            }
            .frame(width: DS.ChatPanel.voiceSampleButtonSizeInPoints, height: DS.ChatPanel.voiceSampleButtonSizeInPoints)
            .contentShape(Circle())
            .brightness(isHovered ? 0.1 : 0)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
        .accessibilityLabel(rowState == .idle ? "play a sample of \(voiceTitle)" : "stop the sample of \(voiceTitle)")
    }
}

// MARK: - The LOOK section's pieces (round 20)

/// One colour of the palette: a round swatch that chooses the colour. The chosen one has a ring in
/// the panel's primary text colour around it; every swatch has a faint edge (so a dark colour shows
/// its outline on the dark panel), brightens under the pointer and shows the pointing hand.
private struct EzraCursorColourSwatchButton: View {
    let paletteEntry: EzraCursorPaletteEntry
    let isChosen: Bool
    let onChoose: () -> Void

    @State private var isHovered = false

    private var outerSideInPoints: CGFloat {
        DS.ChatPanel.colourSwatchDiameterInPoints + 2 * (DS.ChatPanel.colourSwatchRingGapInPoints + DS.ChatPanel.colourSwatchRingWidthInPoints)
    }

    var body: some View {
        Button(action: onChoose) {
            ZStack {
                Circle()
                    .fill(DS.Colors.overlayCursorColour(forHex: paletteEntry.hex))
                    .overlay(Circle().stroke(DS.Colors.chatPanelColourSwatchEdge, lineWidth: 1))
                    .frame(width: DS.ChatPanel.colourSwatchDiameterInPoints, height: DS.ChatPanel.colourSwatchDiameterInPoints)
                if isChosen {
                    Circle()
                        .stroke(DS.Colors.chatPanelColourSwatchRing, lineWidth: DS.ChatPanel.colourSwatchRingWidthInPoints)
                        .frame(
                            width: outerSideInPoints - DS.ChatPanel.colourSwatchRingWidthInPoints,
                            height: outerSideInPoints - DS.ChatPanel.colourSwatchRingWidthInPoints
                        )
                }
            }
            .frame(width: outerSideInPoints, height: outerSideInPoints)
            .contentShape(Circle())
            .brightness(isHovered ? 0.12 : 0)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
        .accessibilityLabel(paletteEntry.name)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

/// The LOOK section's live preview: the chosen cursor on a dark half and on a light half, each with
/// the shape at its rest angle and glow and, under it, the waveform and the spinner in the same
/// colour. Drawn with the overlay's own views (EzraCursorViews.swift), so it is what the cursor
/// looks like. Not interactive, so it shows no hover state.
struct EzraCursorStylePreview: View {
    let cursorStyle: EzraCursorStyle

    private var cursorColour: Color {
        DS.Colors.overlayCursorColour(forHex: cursorStyle.colourHex)
    }

    /// The square each of the waveform and the spinner gets in the preview: room for their natural
    /// size (at most about 18 points) at the chosen scale.
    private var feedbackFrameSideInPoints: CGFloat {
        DS.ChatPanel.cursorPreviewFeedbackFrameSideInPoints * CGFloat(cursorStyle.size.scale)
    }

    var body: some View {
        HStack(spacing: 0) {
            previewHalf(backgroundColour: DS.Colors.chatPanelCursorPreviewDarkBackground)
            previewHalf(backgroundColour: DS.Colors.chatPanelCursorPreviewLightBackground)
        }
        .frame(width: DS.ChatPanel.cursorPreviewWidthInPoints, height: DS.ChatPanel.cursorPreviewHeightInPoints)
        .clipShape(RoundedRectangle(cornerRadius: DS.ChatPanel.cursorPreviewCornerRadiusInPoints, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.ChatPanel.cursorPreviewCornerRadiusInPoints, style: .continuous)
                .stroke(DS.Colors.chatPanelDivider, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("preview of the cursor: \(cursorStyle.shape.title), \(cursorStyle.size.title), glow \(cursorStyle.glow.title)")
    }

    private func previewHalf(backgroundColour: Color) -> some View {
        ZStack {
            backgroundColour
            VStack(spacing: DS.ChatPanel.cursorPreviewRowSpacingInPoints) {
                EzraStyledCursorShapeView(cursorStyle: cursorStyle, cursorColour: cursorColour)
                    .rotationEffect(.degrees(cursorStyle.shape.restAngleDegrees))
                    .modifier(EzraCursorGlowModifier(cursorGlow: cursorStyle.glow, cursorColour: cursorColour, flightScale: 1))
                // Scaling does not change a view's layout size, so each one gets a frame that grows
                // with the size; otherwise a large waveform and spinner would touch.
                HStack(spacing: DS.ChatPanel.cursorPreviewFeedbackSpacingInPoints) {
                    EzraCursorWaveformView(
                        audioPowerLevel: DS.ChatPanel.cursorPreviewAudioPowerLevel,
                        barColor: cursorColour,
                        glowRadius: cursorStyle.glow.feedbackGlowRadius,
                        glowOpacity: cursorStyle.glow.feedbackGlowOpacity,
                        scale: cursorStyle.size.scale
                    )
                    .frame(width: feedbackFrameSideInPoints, height: feedbackFrameSideInPoints)
                    EzraCursorSpinnerView(
                        spinnerColor: cursorColour,
                        glowRadius: cursorStyle.glow.feedbackGlowRadius,
                        glowOpacity: cursorStyle.glow.feedbackGlowOpacity,
                        scale: cursorStyle.size.scale
                    )
                    .frame(width: feedbackFrameSideInPoints, height: feedbackFrameSideInPoints)
                }
            }
        }
        .frame(width: DS.ChatPanel.cursorPreviewWidthInPoints / 2, height: DS.ChatPanel.cursorPreviewHeightInPoints)
    }
}
