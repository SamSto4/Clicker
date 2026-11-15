import Foundation

// Pure rules behind the settings tab of the chat panel (round 15): the defaults of every setting,
// the "drawings stay" choice and the lifetimes it scales, whether a reply is spoken, the six tabs
// of the panel, the shortcuts cheat sheet and the permission rows. The menu bar panel and the
// chat panel share the same `CompanionManager` state and `UserDefaults` keys, so a setting changed
// in either place shows in the other; this file only holds the decisions, never the state.

// MARK: - The tabs

/// The six tabs in the panel's header, in the order they are shown. Round 21b added "context" (the
/// user's standing context) between memory and usage.
nonisolated enum EzraChatPanelTab: String, CaseIterable, Equatable, Sendable {
    case chat
    case chats
    case memory
    case context
    case usage
    case settings

    /// The word on the tab. Lowercase, like every other word Ezra shows.
    var title: String {
        rawValue
    }

    /// A small SF Symbol shown before the word.
    var symbolName: String {
        switch self {
        case .chat: return "bubble.left"
        case .chats: return "clock.arrow.circlepath"
        case .memory: return "brain"
        case .context: return "doc.text"
        case .usage: return "chart.bar"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Drawings stay

/// How long Ezra's drawing stays on the screen after it has finished speaking: today's lifetimes
/// shortened to half, left as they are, or doubled.
nonisolated enum EzraDrawingLifetimeChoice: String, CaseIterable, Equatable, Sendable {
    case short
    case normal
    case long

    var scale: Double {
        switch self {
        case .short: return 0.5
        case .normal: return 1
        case .long: return 2
        }
    }

    /// The word on the choice.
    var title: String {
        rawValue
    }
}

/// How long each kind of drawing stays after the reply has ended. The standard numbers are the
/// ones the drawing has always had (marks 12 s, the explanation card 20 s, the 3D scene 25 s);
/// the "drawings stay" choice multiplies all three by the same factor, so the card still outlasts
/// the marks and the scene still outlasts the card at every choice.
nonisolated struct EzraDrawingLifetimes: Equatable, Sendable {
    var secondsMarksStayAfterReplyEnds: TimeInterval
    var secondsExplanationCardStaysAfterReplyEnds: TimeInterval
    var secondsSceneStaysAfterReplyEnds: TimeInterval

    static let standard = EzraDrawingLifetimes(
        secondsMarksStayAfterReplyEnds: 12,
        secondsExplanationCardStaysAfterReplyEnds: 20,
        secondsSceneStaysAfterReplyEnds: 25
    )

    func scaled(by scale: Double) -> EzraDrawingLifetimes {
        EzraDrawingLifetimes(
            secondsMarksStayAfterReplyEnds: secondsMarksStayAfterReplyEnds * scale,
            secondsExplanationCardStaysAfterReplyEnds: secondsExplanationCardStaysAfterReplyEnds * scale,
            secondsSceneStaysAfterReplyEnds: secondsSceneStaysAfterReplyEnds * scale
        )
    }

    static func lifetimes(for drawingLifetimeChoice: EzraDrawingLifetimeChoice) -> EzraDrawingLifetimes {
        standard.scaled(by: drawingLifetimeChoice.scale)
    }
}

// MARK: - Settings and their defaults

/// The Claude models the panel offers. The same two the menu bar panel offers.
nonisolated struct EzraPanelModelOption: Equatable, Sendable {
    let title: String
    let modelIdentifier: String

    static let sonnet = EzraPanelModelOption(title: "sonnet", modelIdentifier: "claude-sonnet-5-5")
    /// Opus 5.5 since 12 Nov 2026 (it was the older `claude-opus-4-6`, which has no price in the
    /// usage table and, like every model but Sonnet 5.5, rejected the thinking setting Ezra sent).
    static let opus = EzraPanelModelOption(title: "opus", modelIdentifier: "claude-opus-5-5")
    static let all = [sonnet, opus]

    /// Model identifiers an earlier version stored that now mean another option. A stored
    /// `claude-opus-4-6` (someone who picked "opus" before) reads as today's opus.
    static let replacedModelIdentifiers = ["claude-opus-4-6": opus.modelIdentifier]
}

/// The `UserDefaults` keys and the default of every setting. Each function takes the stored value
/// (what `UserDefaults.object(forKey:)` returned, nil when nothing was stored) so the defaults can
/// be checked without touching `UserDefaults`.
nonisolated enum EzraPanelSettingsDefaults {
    static let selectedModelKey = "selectedClaudeModel"
    /// The stored key keeps its string from before the rename to Ezra: it is data in Sam's
    /// `UserDefaults`, and a new string would reset "show ezra" to its default.
    static let isEzraCursorEnabledKey = "isClickyCursorEnabled"
    static let isDictationEnabledKey = "isDictationEnabled"
    static let isStatusPillEnabledKey = "isStatusPillEnabled"
    static let isSpeakingRepliesEnabledKey = "isSpeakingRepliesEnabled"
    static let isSpeakingTypedRepliesEnabledKey = "isSpeakingTypedRepliesEnabled"
    static let drawingLifetimeScaleKey = "drawingLifetimeScale"
    // Round 18 (Jarvis actions).
    static let isActionsEnabledKey = "isActionsEnabled"
    static let isFollowUpListeningEnabledKey = "isFollowUpListeningEnabled"
    static let personaAssistantNameKey = "personaAssistantName"
    static let personaStyleKey = "personaStyle"
    static let personaUserAddressKey = "personaUserAddress"
    // Round 19 (Jarvis tuning).
    static let isQuickCommandsEnabledKey = "isQuickCommandsEnabled"
    // Round 20 (look and sound): the cursor studio's four keys and the voice picker's three.
    static let cursorColourHexKey = "cursorColourHex"
    static let cursorShapeKey = "cursorShape"
    static let cursorSizeKey = "cursorSize"
    static let cursorGlowKey = "cursorGlow"
    static let chosenVoiceIDKey = "chosenVoiceID"
    static let chosenVoiceNameKey = "chosenVoiceName"
    static let speechSpeedPercentKey = "speechSpeedPercent"

    static let defaultModelIdentifier = EzraPanelModelOption.sonnet.modelIdentifier
    static let defaultIsEzraCursorEnabled = true
    static let defaultIsDictationEnabled = true
    static let defaultIsStatusPillEnabled = true
    /// Replies to voice turns are spoken, as they always were.
    static let defaultIsSpeakingRepliesEnabled = true
    /// Typed replies are only read, as they always were.
    static let defaultIsSpeakingTypedRepliesEnabled = false
    static let defaultDrawingLifetimeChoice = EzraDrawingLifetimeChoice.normal
    /// Actions are on out of the box: Ezra opens apps, links and files, sets timers and reminders,
    /// and runs shortcuts when asked (the risky ones wait for a yes).
    static let defaultIsActionsEnabled = true
    /// After a spoken reply Ezra listens a few seconds for a follow-up.
    static let defaultIsFollowUpListeningEnabled = true
    static let defaultPersonaStyle = EzraPersonaStyle.friendly
    /// Quick commands are on out of the box (Sam's decision of 14 Nov 2026): "open safari" and "set a
    /// timer for 10 minutes" are carried out on this Mac with no model call. They work only while
    /// actions are on.
    static let defaultIsQuickCommandsEnabled = true

    /// A stored true or false, or `defaultValue` when nothing (or something else) is stored.
    static func isEnabled(storedValue: Any?, defaultValue: Bool) -> Bool {
        guard let storedNumber = storedValue as? NSNumber else {
            return defaultValue
        }
        return storedNumber.boolValue
    }

    static func selectedModelIdentifier(storedValue: Any?) -> String {
        guard let storedModelIdentifier = storedValue as? String, !storedModelIdentifier.isEmpty else {
            return defaultModelIdentifier
        }
        return EzraPanelModelOption.replacedModelIdentifiers[storedModelIdentifier] ?? storedModelIdentifier
    }

    /// The stored persona style word. A missing or unknown value is "friendly" (today's behaviour).
    static func personaStyle(storedValue: Any?) -> EzraPersonaStyle {
        guard let storedWord = storedValue as? String,
              let storedStyle = EzraPersonaStyle(rawValue: storedWord) else {
            return defaultPersonaStyle
        }
        return storedStyle
    }

    /// A stored name or form of address, cleaned. Anything that is not text is empty.
    static func personaText(storedValue: Any?) -> String {
        guard let storedText = storedValue as? String else {
            return ""
        }
        return EzraPersona.cleanedName(storedText)
    }

    /// The stored word ("short", "normal" or "long"). A missing or unknown value is "normal".
    static func drawingLifetimeChoice(storedValue: Any?) -> EzraDrawingLifetimeChoice {
        guard let storedWord = storedValue as? String,
              let storedChoice = EzraDrawingLifetimeChoice(rawValue: storedWord) else {
            return defaultDrawingLifetimeChoice
        }
        return storedChoice
    }

    /// The cursor's look from its four stored values (round 20). Each value is read on its own: a
    /// missing or unreadable one falls back to that field's default only, so a bad hex keeps the
    /// chosen shape, size and glow. With nothing stored this is today's cursor.
    static func cursorStyle(storedColourHex: Any?, storedShape: Any?, storedSize: Any?, storedGlow: Any?) -> EzraCursorStyle {
        let defaultStyle = EzraCursorStyle.default
        return EzraCursorStyle(
            colourHex: (storedColourHex as? String).flatMap { EzraCursorColour.parse($0) } ?? defaultStyle.colourHex,
            shape: (storedShape as? String).flatMap { EzraCursorShape(rawValue: $0) } ?? defaultStyle.shape,
            size: (storedSize as? String).flatMap { EzraCursorSize(rawValue: $0) } ?? defaultStyle.size,
            glow: (storedGlow as? String).flatMap { EzraCursorGlow(rawValue: $0) } ?? defaultStyle.glow
        )
    }

    /// The voice and speed from their three stored values (round 20); see `EzraVoiceSettings.settings`.
    static func voiceSettings(storedVoiceID: Any?, storedVoiceName: Any?, storedSpeedPercent: Any?) -> EzraVoiceSettings {
        EzraVoiceSettings.settings(storedVoiceID: storedVoiceID, storedVoiceName: storedVoiceName, storedSpeedPercent: storedSpeedPercent)
    }
}

/// Every setting the settings tab shows, as one value the panel can compare and redraw from.
nonisolated struct EzraPanelSettingsSnapshot: Equatable, Sendable {
    var selectedModelIdentifier: String
    var isEzraCursorEnabled: Bool
    var isDictationEnabled: Bool
    var isStatusPillEnabled: Bool
    var isSpeakingRepliesEnabled: Bool
    var isSpeakingTypedRepliesEnabled: Bool
    var drawingLifetimeChoice: EzraDrawingLifetimeChoice
    // Round 18. They come last and carry their defaults, so every older way of making a snapshot
    // keeps working.
    var isActionsEnabled: Bool = EzraPanelSettingsDefaults.defaultIsActionsEnabled
    var isFollowUpListeningEnabled: Bool = EzraPanelSettingsDefaults.defaultIsFollowUpListeningEnabled
    var personaAssistantName: String = ""
    var personaStyle: EzraPersonaStyle = EzraPanelSettingsDefaults.defaultPersonaStyle
    var personaUserAddress: String = ""
    // Round 19. Last, with its default, like the round 18 fields.
    var isQuickCommandsEnabled: Bool = EzraPanelSettingsDefaults.defaultIsQuickCommandsEnabled
    // Round 20 (look and sound). Last, with their defaults (today's cursor, the Worker's default
    // voice at its own pace), like the fields before them.
    var cursorStyle: EzraCursorStyle = .default
    var chosenVoiceID: String? = nil
    var chosenVoiceName: String? = nil
    var speechSpeedPercent: Int = EzraVoiceSettings.normalSpeedPercent

    /// The persona the three persona settings make.
    var persona: EzraPersona {
        EzraPersona(assistantName: personaAssistantName, style: personaStyle, userAddress: personaUserAddress)
    }

    /// The voice settings the three voice fields make.
    var voiceSettings: EzraVoiceSettings {
        EzraVoiceSettings(chosenVoiceID: chosenVoiceID, chosenVoiceName: chosenVoiceName, speedPercent: speechSpeedPercent)
    }

    /// What every setting is when nothing has been stored.
    static let defaults = EzraPanelSettingsSnapshot(
        selectedModelIdentifier: EzraPanelSettingsDefaults.defaultModelIdentifier,
        isEzraCursorEnabled: EzraPanelSettingsDefaults.defaultIsEzraCursorEnabled,
        isDictationEnabled: EzraPanelSettingsDefaults.defaultIsDictationEnabled,
        isStatusPillEnabled: EzraPanelSettingsDefaults.defaultIsStatusPillEnabled,
        isSpeakingRepliesEnabled: EzraPanelSettingsDefaults.defaultIsSpeakingRepliesEnabled,
        isSpeakingTypedRepliesEnabled: EzraPanelSettingsDefaults.defaultIsSpeakingTypedRepliesEnabled,
        drawingLifetimeChoice: EzraPanelSettingsDefaults.defaultDrawingLifetimeChoice
    )

    func applying(_ change: EzraPanelSettingChange) -> EzraPanelSettingsSnapshot {
        var changedSnapshot = self
        switch change {
        case .selectedModel(let modelIdentifier):
            changedSnapshot.selectedModelIdentifier = modelIdentifier
        case .ezraCursorEnabled(let isEnabled):
            changedSnapshot.isEzraCursorEnabled = isEnabled
        case .dictationEnabled(let isEnabled):
            changedSnapshot.isDictationEnabled = isEnabled
        case .statusPillEnabled(let isEnabled):
            changedSnapshot.isStatusPillEnabled = isEnabled
        case .speakingRepliesEnabled(let isEnabled):
            changedSnapshot.isSpeakingRepliesEnabled = isEnabled
        case .speakingTypedRepliesEnabled(let isEnabled):
            changedSnapshot.isSpeakingTypedRepliesEnabled = isEnabled
        case .drawingLifetime(let drawingLifetimeChoice):
            changedSnapshot.drawingLifetimeChoice = drawingLifetimeChoice
        case .actionsEnabled(let isEnabled):
            changedSnapshot.isActionsEnabled = isEnabled
        case .followUpListeningEnabled(let isEnabled):
            changedSnapshot.isFollowUpListeningEnabled = isEnabled
        case .personaAssistantName(let name):
            changedSnapshot.personaAssistantName = EzraPersona.cleanedName(name)
        case .personaStyle(let style):
            changedSnapshot.personaStyle = style
        case .personaUserAddress(let address):
            changedSnapshot.personaUserAddress = EzraPersona.cleanedName(address)
        case .quickCommandsEnabled(let isEnabled):
            changedSnapshot.isQuickCommandsEnabled = isEnabled
        case .cursorColourHex(let typedColourText):
            // Only a colour that parses is taken; anything else leaves the colour as it was.
            if let colourHex = EzraCursorColour.parse(typedColourText) {
                changedSnapshot.cursorStyle.colourHex = colourHex
            }
        case .cursorShape(let shape):
            changedSnapshot.cursorStyle.shape = shape
        case .cursorSize(let size):
            changedSnapshot.cursorStyle.size = size
        case .cursorGlow(let glow):
            changedSnapshot.cursorStyle.glow = glow
        case .chosenVoice(let voiceID, let voiceName):
            // A usable id with its (cleaned) name, or nothing at all: back to the Worker's default.
            let chosenSettings = EzraVoiceSettings.settings(storedVoiceID: voiceID, storedVoiceName: voiceName, storedSpeedPercent: nil)
            changedSnapshot.chosenVoiceID = chosenSettings.chosenVoiceID
            changedSnapshot.chosenVoiceName = chosenSettings.chosenVoiceName
        case .speechSpeedPercent(let speedPercent):
            changedSnapshot.speechSpeedPercent = EzraVoiceSettings.speedStep(forPercent: speedPercent)
        }
        return changedSnapshot
    }
}

/// One change the user made in the settings tab. The panel hands it to `CompanionManager`, which
/// stores it in `UserDefaults` exactly as the menu bar panel's own switches do.
nonisolated enum EzraPanelSettingChange: Equatable, Sendable {
    case selectedModel(String)
    case ezraCursorEnabled(Bool)
    case dictationEnabled(Bool)
    case statusPillEnabled(Bool)
    case speakingRepliesEnabled(Bool)
    case speakingTypedRepliesEnabled(Bool)
    case drawingLifetime(EzraDrawingLifetimeChoice)
    case actionsEnabled(Bool)
    case followUpListeningEnabled(Bool)
    case personaAssistantName(String)
    case personaStyle(EzraPersonaStyle)
    case personaUserAddress(String)
    case quickCommandsEnabled(Bool)
    // Round 20 (look and sound).
    /// What was typed in the hex field or picked from the palette; only a colour that parses is taken.
    case cursorColourHex(String)
    case cursorShape(EzraCursorShape)
    case cursorSize(EzraCursorSize)
    case cursorGlow(EzraCursorGlow)
    /// A voice of the account with its name, or (nil, nil) for the Worker's default voice.
    case chosenVoice(id: String?, name: String?)
    case speechSpeedPercent(Int)
}

// MARK: - Whether a reply is spoken

nonisolated enum EzraReplySpeechDecision {
    /// Whether the reply of a turn is read aloud.
    /// - "speak replies" is the master switch: with it off nothing is spoken.
    /// - With it on, replies to voice turns are spoken, and replies to typed turns only when
    ///   "speak typed replies" is on too.
    /// With the defaults (on, off) this is exactly `inputMode == .spoken`, which is what Ezra
    /// did before these switches existed.
    static func shouldSpeakReply(
        inputMode: EzraTurnInputMode,
        isSpeakingRepliesEnabled: Bool,
        isSpeakingTypedRepliesEnabled: Bool
    ) -> Bool {
        guard isSpeakingRepliesEnabled else {
            return false
        }
        switch inputMode {
        case .spoken:
            return true
        case .typed:
            return isSpeakingTypedRepliesEnabled
        }
    }

    /// A voice turn whose reply is not spoken has nowhere else to show it, so the panel opens
    /// (without taking the keyboard) and shows the reply as text. A typed reply is already read in
    /// the panel the message was typed in.
    static func shouldShowReplyAsTextInPanel(
        inputMode: EzraTurnInputMode,
        isSpeakingRepliesEnabled: Bool,
        isSpeakingTypedRepliesEnabled: Bool
    ) -> Bool {
        inputMode == .spoken && !shouldSpeakReply(
            inputMode: inputMode,
            isSpeakingRepliesEnabled: isSpeakingRepliesEnabled,
            isSpeakingTypedRepliesEnabled: isSpeakingTypedRepliesEnabled
        )
    }
}

// MARK: - Shortcuts cheat sheet

/// One line of the cheat sheet: the keys and what they do.
nonisolated struct EzraShortcutCheatSheetEntry: Equatable, Sendable {
    let keys: String
    let action: String
}

nonisolated enum EzraShortcutCheatSheet {
    static let entries: [EzraShortcutCheatSheetEntry] = [
        EzraShortcutCheatSheetEntry(keys: "ctrl + option", action: "hold to ask ezra"),
        EzraShortcutCheatSheetEntry(keys: "fn + option", action: "hold to dictate · double-tap for hands-free"),
        EzraShortcutCheatSheetEntry(keys: "⌥⌘", action: "tap to open this panel"),
        EzraShortcutCheatSheetEntry(keys: "esc", action: "stop ezra or clear drawings"),
    ]
}

// MARK: - Permissions

/// The permissions the settings tab shows (the four of round 15, and reminders since round 18).
nonisolated enum EzraPermissionKind: String, CaseIterable, Equatable, Sendable {
    case microphone
    case speechRecognition
    case screenRecording
    case accessibility
    case reminders

    var title: String {
        switch self {
        case .microphone: return "microphone"
        case .speechRecognition: return "speech recognition"
        case .screenRecording: return "screen recording"
        case .accessibility: return "accessibility"
        case .reminders: return "reminders"
        }
    }

    var symbolName: String {
        switch self {
        case .microphone: return "mic"
        case .speechRecognition: return "waveform"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility: return "hand.raised"
        case .reminders: return "checklist"
        }
    }

    /// What Ezra uses it for, in a few words.
    var purpose: String {
        switch self {
        case .microphone: return "hear you when you ask or dictate"
        case .speechRecognition: return "turn what you say into words, on this mac"
        case .screenRecording: return "see your screen when you ask"
        case .accessibility: return "read shortcuts and paste dictated words"
        case .reminders: return "add and read reminders when you ask"
        }
    }
}

nonisolated struct EzraPermissionStatus: Equatable, Sendable {
    let kind: EzraPermissionKind
    let isGranted: Bool
}
