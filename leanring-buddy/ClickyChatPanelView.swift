//
//  ClickyChatPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content of the chat panel that drops down from the notch: five tabs. "chat" has a
//  text field to type to Clicky and the current chat with the reply streaming in; "chats" lists
//  past chats grouped by project with search, open, continue, keep and delete; "memory", "usage"
//  and "settings" are in ClickyChatPanelMemoryView, ClickyChatPanelUsageView and
//  ClickyChatPanelSettingsView.
//
//  Every colour and size is a `DS.Colors.chatPanel...` or `DS.ChatPanel` token. Every button has
//  a pointer cursor and a hover state. The view needs nothing from the rest of the app except its
//  view model, so it can be rendered offscreen.
//

import AppKit
import SwiftUI

// MARK: - Measuring

/// Carries the height of a piece of the layout up to the view that sizes the panel.
private struct ClickyChatPanelHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Reports this view's height (the height it chose, not the room it was offered).
    func reportingHeight(_ reportHeight: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { geometryProxy in
                Color.clear.preference(key: ClickyChatPanelHeightPreferenceKey.self, value: geometryProxy.size.height)
            }
        )
        .onPreferenceChange(ClickyChatPanelHeightPreferenceKey.self) { measuredHeight in
            reportHeight(measuredHeight)
        }
    }
}

// MARK: - Button styles

/// A small word-button: "continue", "keep", "delete", "chats". Lights up under the pointer, shows
/// the pointing hand, and dims while pressed. Also used by the memory, usage and settings tabs.
struct ClickyChatTextButtonStyle: ButtonStyle {
    var isDestructive = false
    var isProminent = false

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: DS.ChatPanel.textActionFontSizeInPoints, weight: .medium))
            .foregroundColor(labelColor)
            .padding(.horizontal, DS.ChatPanel.textActionHorizontalPaddingInPoints)
            .padding(.vertical, DS.ChatPanel.textActionVerticalPaddingInPoints)
            .background(
                RoundedRectangle(cornerRadius: DS.ChatPanel.iconButtonCornerRadiusInPoints - 2, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.ChatPanel.iconButtonCornerRadiusInPoints - 2, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = $0 }
            .pointerCursor()
    }

    private var labelColor: Color {
        if isDestructive { return isHovered ? DS.Colors.destructiveText : DS.Colors.chatPanelSecondaryText }
        if isProminent { return isHovered ? DS.Colors.textOnAccent : DS.Colors.accentText }
        return isHovered ? DS.Colors.chatPanelPrimaryText : DS.Colors.chatPanelSecondaryText
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isDestructive && isHovered { return DS.Colors.destructive.opacity(0.18) }
        if isProminent && isHovered { return DS.Colors.accent }
        if isProminent { return DS.Colors.accentSubtle }
        if isPressed { return DS.Colors.surface3 }
        return isHovered ? DS.Colors.chatPanelRowHoverBackground : Color.clear
    }
}

/// A square icon button (back, clear search).
struct ClickyChatIconButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: DS.ChatPanel.iconFontSizeInPoints, weight: .semibold))
            .foregroundColor(isHovered ? DS.Colors.chatPanelPrimaryText : DS.Colors.chatPanelSecondaryText)
            .frame(width: DS.ChatPanel.iconButtonSizeInPoints, height: DS.ChatPanel.iconButtonSizeInPoints)
            .background(
                RoundedRectangle(cornerRadius: DS.ChatPanel.iconButtonCornerRadiusInPoints, style: .continuous)
                    .fill(configuration.isPressed ? DS.Colors.surface3 : (isHovered ? DS.Colors.chatPanelRowHoverBackground : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.ChatPanel.iconButtonCornerRadiusInPoints, style: .continuous))
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = $0 }
            .pointerCursor()
    }
}

/// One tab of the header: an icon and a word. The tab that is showing is lit in blue; the others
/// light up under the pointer, and every one shows the pointing hand.
private struct ClickyChatTabButtonStyle: ButtonStyle {
    let isSelected: Bool

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: DS.ChatPanel.tabLabelFontSizeInPoints, weight: .medium))
            .foregroundColor(labelColor)
            .frame(maxWidth: .infinity)
            .frame(height: DS.ChatPanel.tabHeightInPoints)
            .background(
                RoundedRectangle(cornerRadius: DS.ChatPanel.tabCornerRadiusInPoints, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.ChatPanel.tabCornerRadiusInPoints, style: .continuous))
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = $0 }
            .pointerCursor()
    }

    private var labelColor: Color {
        if isSelected { return DS.Colors.chatPanelTabSelectedText }
        return isHovered ? DS.Colors.chatPanelPrimaryText : DS.Colors.chatPanelSecondaryText
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isSelected { return DS.Colors.chatPanelTabSelectedBackground }
        if isPressed { return DS.Colors.surface3 }
        return isHovered ? DS.Colors.chatPanelRowHoverBackground : Color.clear
    }
}

/// A row of the chat list: lit by the pointer and by the arrow keys' highlight.
private struct ClickyChatRowButtonStyle: ButtonStyle {
    let isHighlightedByKeyboard: Bool
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: DS.ChatPanel.listRowCornerRadiusInPoints, style: .continuous)
                    .fill(rowBackgroundColor(isPressed: configuration.isPressed))
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.ChatPanel.listRowCornerRadiusInPoints, style: .continuous))
            .pointerCursor()
    }

    private func rowBackgroundColor(isPressed: Bool) -> Color {
        if isPressed { return DS.Colors.surface3 }
        if isHighlightedByKeyboard { return DS.Colors.chatPanelRowSelectedBackground }
        return isHovered ? DS.Colors.chatPanelRowHoverBackground : Color.clear
    }
}

// MARK: - The panel

struct ClickyChatPanelView: View {
    @ObservedObject var viewModel: ClickyChatPanelViewModel

    /// The height of the header and the status row, measured, so the messages are given exactly
    /// the room that is left under the panel's height limit.
    @State private var chromeHeightInPoints: CGFloat = 0
    /// The height the messages (or the list) would have with no limit.
    @State private var bodyContentHeightInPoints: CGFloat = 0
    @State private var inputNeededHeightInPoints: CGFloat = 20
    /// The time the list's "5 min ago" texts are counted to. Taken when the view is made, which
    /// is when the panel opens and each time its chats change.
    private let now = Date()

    private static let dividerHeightInPoints: CGFloat = 1
    private static let smallestBodyHeightInPoints: CGFloat = 40

    private var panelShape: AnyShape {
        if viewModel.hangsFromNotch {
            return AnyShape(UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: DS.ChatPanel.notchCornerRadiusInPoints,
                bottomTrailingRadius: DS.ChatPanel.notchCornerRadiusInPoints,
                topTrailingRadius: 0,
                style: .continuous
            ))
        }
        return AnyShape(RoundedRectangle(cornerRadius: DS.ChatPanel.cornerRadiusInPoints, style: .continuous))
    }

    private var largestBodyHeightInPoints: CGFloat {
        max(
            Self.smallestBodyHeightInPoints,
            DS.ChatPanel.maximumHeightInPoints - chromeHeightInPoints - Self.dividerHeightInPoints
        )
    }

    private var bodyHeightInPoints: CGFloat {
        min(max(bodyContentHeightInPoints, Self.smallestBodyHeightInPoints), largestBodyHeightInPoints)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                headerRow
                if let statusContent = viewModel.statusContent {
                    statusRow(for: statusContent)
                }
            }
            .reportingHeight { chromeHeightInPoints = $0 }

            Rectangle()
                .fill(DS.Colors.chatPanelDivider)
                .frame(height: Self.dividerHeightInPoints)

            bodyArea
                .frame(height: bodyHeightInPoints)
        }
        .frame(width: DS.ChatPanel.widthInPoints)
        .reportingHeight { totalHeight in
            viewModel.updateDesiredPanelHeight(totalHeight)
        }
        .background(panelBackground)
        .clipShape(panelShape)
        .overlay(panelEdge)
        // The window is sized to the panel's own height, and the panel hangs from the top.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var panelBackground: some View {
        panelShape.fill(
            viewModel.hangsFromNotch
                ? DS.Colors.chatPanelNotchBackground
                : DS.Colors.chatPanelBackground.opacity(DS.ChatPanel.backgroundOpacity)
        )
    }

    /// A faint edge below a menu bar. Under a notch an edge would draw a line between the notch
    /// and the panel, so there is none.
    @ViewBuilder
    private var panelEdge: some View {
        if !viewModel.hangsFromNotch {
            panelShape.stroke(DS.Colors.chatPanelBorder, lineWidth: DS.ChatPanel.borderWidthInPoints)
        }
    }

    // MARK: - Header

    /// The tab bar on top, and under it what belongs to the tab that is showing: the text field of
    /// the chat tab, the search field of the chats tab, the title row of an old chat being read.
    /// The memory, usage and settings tabs have nothing under the bar.
    private var headerRow: some View {
        VStack(spacing: DS.ChatPanel.belowTabBarSpacingInPoints) {
            tabBar
            tabHeaderRow
        }
        .padding(.horizontal, DS.ChatPanel.horizontalPaddingInPoints)
        .padding(.top, DS.ChatPanel.tabBarTopPaddingInPoints)
        .padding(.bottom, viewModel.screen.hasRowUnderTabBar ? DS.ChatPanel.headerBottomPaddingInPoints : DS.ChatPanel.tabBarBottomPaddingInPoints)
    }

    private var tabBar: some View {
        HStack(spacing: DS.ChatPanel.tabSpacingInPoints) {
            ForEach(ClickyChatPanelTab.allCases, id: \.self) { tab in
                Button(action: { viewModel.selectTab(tab) }) {
                    HStack(spacing: DS.ChatPanel.tabIconLabelSpacingInPoints) {
                        Image(systemName: tab.symbolName)
                            .font(.system(size: DS.ChatPanel.tabIconFontSizeInPoints, weight: .medium))
                        Text(tab.title)
                    }
                }
                .buttonStyle(ClickyChatTabButtonStyle(isSelected: viewModel.selectedTab == tab))
                .accessibilityLabel("show the \(tab.title) tab")
                .accessibilityAddTraits(viewModel.selectedTab == tab ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private var tabHeaderRow: some View {
        switch viewModel.screen {
        case .activeChat:
            HStack(alignment: .top, spacing: DS.ChatPanel.headerSpacingInPoints) {
                askField
                newChatButton
                    .padding(.top, 5)
            }
        case .chatList:
            HStack(alignment: .center, spacing: DS.ChatPanel.headerSpacingInPoints) {
                searchField
                newChatButton
            }
        case .readOnlyChat(let chatID):
            readOnlyChatHeader(chatID: chatID)
        case .memory, .usage, .settings:
            EmptyView()
        }
    }

    private var newChatButton: some View {
        Button(action: { viewModel.startNewChat() }) {
            Label("new chat", systemImage: "plus.bubble")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(ClickyChatTextButtonStyle())
        .accessibilityLabel("start a new chat")
    }

    private var askField: some View {
        ZStack(alignment: .topLeading) {
            if viewModel.draftMessageText.isEmpty {
                Text("ask clicky…")
                    .font(.system(size: DS.ChatPanel.inputFontSizeInPoints))
                    .foregroundColor(DS.Colors.chatPanelTertiaryText)
                    .allowsHitTesting(false)
            }
            ClickyChatTextInput(
                text: $viewModel.draftMessageText,
                allowsMultipleLines: true,
                focusRequestCount: viewModel.inputFocusRequestCount,
                onSubmit: { viewModel.sendDraftMessage() },
                maximumVisibleLineCount: DS.ChatPanel.inputMaximumVisibleLineCount,
                onNeededHeightChange: { neededHeight in
                    inputNeededHeightInPoints = neededHeight
                }
            )
            .frame(height: inputNeededHeightInPoints)
        }
        .padding(.horizontal, DS.ChatPanel.inputHorizontalPaddingInPoints)
        .padding(.vertical, DS.ChatPanel.inputVerticalPaddingInPoints)
        .background(
            RoundedRectangle(cornerRadius: DS.ChatPanel.inputCornerRadiusInPoints, style: .continuous)
                .fill(DS.Colors.chatPanelInputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.ChatPanel.inputCornerRadiusInPoints, style: .continuous)
                .stroke(DS.Colors.chatPanelDivider, lineWidth: 1)
        )
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DS.ChatPanel.iconFontSizeInPoints, weight: .medium))
                .foregroundColor(DS.Colors.chatPanelTertiaryText)

            ZStack(alignment: .leading) {
                if viewModel.searchQueryText.isEmpty {
                    Text("search chats…")
                        .font(.system(size: DS.ChatPanel.inputFontSizeInPoints))
                        .foregroundColor(DS.Colors.chatPanelTertiaryText)
                        .allowsHitTesting(false)
                }
                ClickyChatTextInput(
                    text: $viewModel.searchQueryText,
                    allowsMultipleLines: false,
                    focusRequestCount: viewModel.inputFocusRequestCount,
                    onSubmit: { viewModel.openSelectedChatToRead() },
                    maximumVisibleLineCount: 1,
                    onNeededHeightChange: { _ in }
                )
                .frame(height: 20)
            }

            if !viewModel.searchQueryText.isEmpty {
                Button(action: { viewModel.searchQueryText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(ClickyChatIconButtonStyle())
                .accessibilityLabel("clear the search")
                .frame(width: 20, height: 20)
            }
        }
        .padding(.horizontal, DS.ChatPanel.inputHorizontalPaddingInPoints)
        .padding(.vertical, DS.ChatPanel.inputVerticalPaddingInPoints)
        .background(
            RoundedRectangle(cornerRadius: DS.ChatPanel.inputCornerRadiusInPoints, style: .continuous)
                .fill(DS.Colors.chatPanelInputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.ChatPanel.inputCornerRadiusInPoints, style: .continuous)
                .stroke(DS.Colors.chatPanelDivider, lineWidth: 1)
        )
        .onChange(of: viewModel.searchQueryText) { _, _ in
            viewModel.reconcileSelectionWithVisibleChats()
        }
    }

    private func readOnlyChatHeader(chatID: UUID) -> some View {
        let chatBeingRead = viewModel.session.collection.chat(withID: chatID)
        return HStack(alignment: .center, spacing: DS.ChatPanel.headerSpacingInPoints) {
            Button(action: { viewModel.showChatList() }) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(ClickyChatIconButtonStyle())
            .accessibilityLabel("back to the chat list")

            VStack(alignment: .leading, spacing: 1) {
                Text(chatBeingRead?.title ?? "")
                    .font(.system(size: DS.ChatPanel.rowTitleFontSizeInPoints, weight: .medium))
                    .foregroundColor(DS.Colors.chatPanelPrimaryText)
                    .lineLimit(1)
                Text(chatBeingRead?.project.displayName ?? "")
                    .font(.system(size: DS.ChatPanel.rowDetailFontSizeInPoints))
                    .foregroundColor(DS.Colors.chatPanelTertiaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: { viewModel.toggleKept(chatID: chatID) }) {
                Text(chatBeingRead?.isKept == true ? "unkeep" : "keep")
            }
            .buttonStyle(ClickyChatTextButtonStyle())

            Button(action: { viewModel.continueChat(chatID: chatID) }) {
                Text("continue this chat")
            }
            .buttonStyle(ClickyChatTextButtonStyle(isProminent: true))
        }
    }

    // MARK: - Status

    private func statusRow(for statusContent: ClickyStatusPillContent) -> some View {
        HStack(spacing: 8) {
            ClickyChatStatusIndicatorView(indicator: statusContent.indicator, accent: statusContent.accent)
            Text(statusContent.word)
                .font(.system(size: DS.ChatPanel.statusWordFontSizeInPoints, weight: .medium))
                .foregroundColor(accentColor(for: statusContent.accent))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.ChatPanel.horizontalPaddingInPoints)
        .frame(height: DS.ChatPanel.statusRowHeightInPoints)
        .padding(.bottom, 4)
    }

    private func accentColor(for accent: ClickyStatusPillAccent) -> Color {
        switch accent {
        case .asking: return DS.Colors.chatPanelAskingAccent
        case .dictating: return DS.Colors.chatPanelDictatingAccent
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var bodyArea: some View {
        switch viewModel.screen {
        case .activeChat, .readOnlyChat:
            transcriptArea
        case .chatList:
            chatListArea
        case .memory:
            tabScrollArea { ClickyChatPanelMemoryContentView(viewModel: viewModel) }
        case .usage:
            tabScrollArea { ClickyChatPanelUsageContentView(viewModel: viewModel) }
        case .settings:
            tabScrollArea { ClickyChatPanelSettingsContentView(viewModel: viewModel) }
        }
    }

    /// The scrolling body of the memory, usage and settings tabs. The panel grows with the content
    /// up to its maximum height and the content scrolls beyond that, like the other tabs.
    private func tabScrollArea<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(.horizontal, DS.ChatPanel.horizontalPaddingInPoints)
                .padding(.vertical, DS.ChatPanel.bodyVerticalPaddingInPoints)
                .frame(maxWidth: .infinity, alignment: .leading)
                .reportingHeight { bodyContentHeightInPoints = $0 }
        }
    }

    // MARK: - Messages

    private var transcriptArea: some View {
        ScrollViewReader { scrollViewProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.ChatPanel.messageSpacingInPoints) {
                    transcriptMessages
                    Color.clear.frame(height: 1).id("clickyChatPanelBottom")
                }
                .padding(.horizontal, DS.ChatPanel.horizontalPaddingInPoints)
                .padding(.vertical, DS.ChatPanel.bodyVerticalPaddingInPoints)
                .frame(maxWidth: .infinity, alignment: .leading)
                .reportingHeight { bodyContentHeightInPoints = $0 }
            }
            .defaultScrollAnchor(viewModel.screen == .activeChat ? .bottom : .top)
            .onChange(of: viewModel.streamingReplyText) { _, _ in
                scrollViewProxy.scrollTo("clickyChatPanelBottom", anchor: .bottom)
            }
            .onChange(of: viewModel.pendingUserMessageText) { _, _ in
                scrollViewProxy.scrollTo("clickyChatPanelBottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private var transcriptMessages: some View {
        let chatToShow = viewModel.displayedChat
        let showsPendingExchange = viewModel.screen == .activeChat && viewModel.pendingUserMessageText != nil

        if (chatToShow?.exchanges.isEmpty ?? true) && !showsPendingExchange && viewModel.turnErrorText == nil {
            emptyChatHint
        }

        if let chatToShow {
            ForEach(Array(chatToShow.exchanges.enumerated()), id: \.offset) { _, exchange in
                userBubble(text: exchange.userText, inputMode: exchange.inputMode)
                replyText(exchange.replyDisplayText.isEmpty ? "(drew on your screen)" : exchange.replyDisplayText)
            }
        }

        if showsPendingExchange, let pendingUserMessageText = viewModel.pendingUserMessageText {
            userBubble(text: pendingUserMessageText, inputMode: viewModel.pendingInputMode)
            if !viewModel.streamingReplyText.isEmpty {
                replyText(viewModel.streamingReplyText)
            }
        }

        if viewModel.screen == .activeChat, let turnErrorText = viewModel.turnErrorText {
            Text(turnErrorText)
                .font(.system(size: DS.ChatPanel.messageFontSizeInPoints))
                .foregroundColor(DS.Colors.chatPanelErrorText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyChatHint: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("ask about what's on your screen.")
                .font(.system(size: DS.ChatPanel.messageFontSizeInPoints, weight: .medium))
                .foregroundColor(DS.Colors.chatPanelSecondaryText)
            Text("return sends · shift + return adds a line · esc closes")
                .font(.system(size: DS.ChatPanel.rowDetailFontSizeInPoints))
                .foregroundColor(DS.Colors.chatPanelTertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func userBubble(text: String, inputMode: ClickyTurnInputMode) -> some View {
        // The mic and the bubble are one group, so the mic sits against the bubble's own edge
        // however short the message is, and the group is pushed to the right.
        HStack(alignment: .center, spacing: 6) {
            if inputMode == .spoken {
                // The words were spoken, not typed.
                Image(systemName: "mic.fill")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.chatPanelTertiaryText)
            }
            Text(text)
                .font(.system(size: DS.ChatPanel.messageFontSizeInPoints))
                .foregroundColor(DS.Colors.chatPanelUserBubbleText)
                .textSelection(.enabled)
                .padding(.horizontal, DS.ChatPanel.userBubbleHorizontalPaddingInPoints)
                .padding(.vertical, DS.ChatPanel.userBubbleVerticalPaddingInPoints)
                .background(
                    RoundedRectangle(cornerRadius: DS.ChatPanel.userBubbleCornerRadiusInPoints, style: .continuous)
                        .fill(DS.Colors.chatPanelUserBubble)
                )
        }
        .frame(maxWidth: DS.ChatPanel.userBubbleMaximumWidthInPoints, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func replyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: DS.ChatPanel.messageFontSizeInPoints))
            .foregroundColor(DS.Colors.chatPanelPrimaryText)
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Chat list

    private var chatListArea: some View {
        ScrollViewReader { scrollViewProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    chatListRows
                }
                .padding(.horizontal, DS.ChatPanel.horizontalPaddingInPoints - 6)
                .padding(.vertical, DS.ChatPanel.bodyVerticalPaddingInPoints - 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .reportingHeight { bodyContentHeightInPoints = $0 }
            }
            .onChange(of: viewModel.selectedChatID) { _, newSelectedChatID in
                guard let newSelectedChatID else { return }
                scrollViewProxy.scrollTo(newSelectedChatID)
            }
        }
    }

    @ViewBuilder
    private var chatListRows: some View {
        let projectGroups = viewModel.visibleProjectGroups
        if projectGroups.isEmpty {
            Text(viewModel.isSearching ? "no chats match “\(viewModel.searchQueryText.trimmingCharacters(in: .whitespacesAndNewlines))”." : "no chats yet. ask something and it shows up here.")
                .font(.system(size: DS.ChatPanel.messageFontSizeInPoints))
                .foregroundColor(DS.Colors.chatPanelSecondaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
        } else {
            ForEach(projectGroups) { projectGroup in
                Text(projectGroup.project.displayName.uppercased())
                    .font(.system(size: DS.ChatPanel.sectionTitleFontSizeInPoints, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(DS.Colors.chatPanelTertiaryText)
                    .padding(.horizontal, DS.ChatPanel.listRowHorizontalPaddingInPoints)
                    .padding(.top, DS.ChatPanel.listSectionTopPaddingInPoints)
                    .padding(.bottom, 4)

                ForEach(projectGroup.chats) { chat in
                    ClickyChatListRowView(viewModel: viewModel, chat: chat, now: now)
                        .id(chat.id)
                }
            }
            Text("chats stay on this mac · deleted \(ClickyChatRetention.retentionDays) days after the last message unless kept")
                .font(.system(size: DS.ChatPanel.footnoteFontSizeInPoints))
                .foregroundColor(DS.Colors.chatPanelTertiaryText)
                .padding(.horizontal, DS.ChatPanel.listRowHorizontalPaddingInPoints)
                .padding(.top, 12)
                .padding(.bottom, 4)
        }
    }
}

// MARK: - A row of the chat list

private struct ClickyChatListRowView: View {
    @ObservedObject var viewModel: ClickyChatPanelViewModel
    let chat: ClickyChat
    let now: Date

    @State private var isHovered = false

    private var isHighlightedByKeyboard: Bool {
        viewModel.selectedChatID == chat.id
    }

    private var isAskingToConfirmDelete: Bool {
        viewModel.chatIDAwaitingDeleteConfirmation == chat.id
    }

    private var showsActions: Bool {
        isHovered || isHighlightedByKeyboard || isAskingToConfirmDelete
    }

    var body: some View {
        Button(action: { viewModel.openChatToRead(chatID: chat.id) }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if chat.isKept {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundColor(DS.Colors.chatPanelKeptMark)
                    }
                    Text(chat.title)
                        .font(.system(size: DS.ChatPanel.rowTitleFontSizeInPoints, weight: .medium))
                        .foregroundColor(DS.Colors.chatPanelPrimaryText)
                        .lineLimit(1)
                }
                Text(detailLine)
                    .font(.system(size: DS.ChatPanel.rowDetailFontSizeInPoints))
                    .foregroundColor(DS.Colors.chatPanelSecondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, DS.ChatPanel.listRowHorizontalPaddingInPoints)
            .padding(.vertical, DS.ChatPanel.listRowVerticalPaddingInPoints)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(ClickyChatRowButtonStyle(isHighlightedByKeyboard: isHighlightedByKeyboard, isHovered: isHovered))
        // The buttons are an overlay of the row (not inside the row's own button, where a button
        // within a button would not take clicks), as tall as the row, in the row's own colour so
        // they hide the end of the preview line under them.
        .overlay(alignment: .trailing) {
            if showsActions {
                actionButtons
                    .padding(.trailing, 6)
                    .padding(.leading, 12)
                    .frame(maxHeight: .infinity)
                    .background(rowBackgroundBehindActions)
            }
        }
        .onHover { isHovered = $0 }
    }

    private var detailLine: String {
        let timeText = ClickyChatTimeText.text(for: chat.updatedAt, now: now)
        let previewText = chat.previewText
        return previewText.isEmpty ? timeText : "\(timeText) · \(previewText)"
    }

    private var rowBackgroundBehindActions: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: DS.ChatPanel.listRowCornerRadiusInPoints,
            topTrailingRadius: DS.ChatPanel.listRowCornerRadiusInPoints,
            style: .continuous
        )
        .fill(isHighlightedByKeyboard ? DS.Colors.chatPanelRowSelectedBackground : DS.Colors.chatPanelRowHoverBackground)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if isAskingToConfirmDelete {
            HStack(spacing: 4) {
                Text("delete this chat?")
                    .font(.system(size: DS.ChatPanel.textActionFontSizeInPoints))
                    .foregroundColor(DS.Colors.chatPanelSecondaryText)
                Button(action: { viewModel.confirmDeleting(chatID: chat.id) }) {
                    Text("delete")
                }
                .buttonStyle(ClickyChatTextButtonStyle(isDestructive: true))
                Button(action: { viewModel.cancelDeleteConfirmation() }) {
                    Text("cancel")
                }
                .buttonStyle(ClickyChatTextButtonStyle())
            }
        } else {
            HStack(spacing: 2) {
                Button(action: { viewModel.continueChat(chatID: chat.id) }) {
                    Text("continue")
                }
                .buttonStyle(ClickyChatTextButtonStyle(isProminent: true))
                Button(action: { viewModel.toggleKept(chatID: chat.id) }) {
                    Text(chat.isKept ? "unkeep" : "keep")
                }
                .buttonStyle(ClickyChatTextButtonStyle())
                Button(action: { viewModel.askToConfirmDeleting(chatID: chat.id) }) {
                    Text("delete")
                }
                .buttonStyle(ClickyChatTextButtonStyle(isDestructive: true))
            }
        }
    }
}

// MARK: - The live word

/// The small moving picture beside the word in the panel: three dots while thinking, bars while
/// listening, a wave while speaking. It is drawn with SwiftUI here (the status pill, which says
/// the same words, is made of Core Animation layers in its own window).
private struct ClickyChatStatusIndicatorView: View {
    let indicator: ClickyStatusPillIndicator
    let accent: ClickyStatusPillAccent

    private var accentColor: Color {
        accent == .dictating ? DS.Colors.chatPanelDictatingAccent : DS.Colors.chatPanelAskingAccent
    }

    var body: some View {
        switch indicator {
        case .thinkingDots:
            thinkingDots
        case .listeningBars:
            listeningBars
        case .speakingWave:
            speakingWave
        case .none:
            EmptyView()
        }
    }

    private var thinkingDots: some View {
        TimelineView(.animation) { timelineContext in
            let secondsIntoLoop = timelineContext.date.timeIntervalSinceReferenceDate
            HStack(spacing: DS.ChatPanel.statusDotSpacingInPoints) {
                ForEach(0..<3, id: \.self) { dotIndex in
                    // Each dot lights up a little after the one before it.
                    let positionInLoop = (secondsIntoLoop / DS.ChatPanel.statusPulseSeconds - Double(dotIndex) * 0.18)
                        .truncatingRemainder(dividingBy: 1)
                    let brightness = 0.3 + 0.7 * max(0, sin(positionInLoop * .pi))
                    Circle()
                        .fill(accentColor)
                        .frame(width: DS.ChatPanel.statusDotDiameterInPoints, height: DS.ChatPanel.statusDotDiameterInPoints)
                        .opacity(brightness)
                }
            }
            .frame(width: DS.ChatPanel.statusIndicatorWidthInPoints, height: DS.ChatPanel.statusIndicatorHeightInPoints)
        }
    }

    private var listeningBars: some View {
        TimelineView(.animation) { timelineContext in
            let secondsNow = timelineContext.date.timeIntervalSinceReferenceDate
            HStack(spacing: DS.ChatPanel.statusBarSpacingInPoints) {
                ForEach(0..<5, id: \.self) { barIndex in
                    let heightShare = 0.35 + 0.65 * abs(sin(secondsNow * 5 + Double(barIndex) * 0.9))
                    Capsule()
                        .fill(accentColor)
                        .frame(width: DS.ChatPanel.statusBarWidthInPoints, height: DS.ChatPanel.statusIndicatorHeightInPoints * heightShare)
                }
            }
            .frame(width: DS.ChatPanel.statusIndicatorWidthInPoints, height: DS.ChatPanel.statusIndicatorHeightInPoints)
        }
    }

    private var speakingWave: some View {
        TimelineView(.animation) { timelineContext in
            let phase = timelineContext.date.timeIntervalSinceReferenceDate * 6
            Canvas { graphicsContext, canvasSize in
                var wavePath = Path()
                let midY = canvasSize.height / 2
                let amplitude = canvasSize.height * 0.32
                for pointX in stride(from: CGFloat(0), through: canvasSize.width, by: 1) {
                    let pointY = midY + amplitude * CGFloat(sin(Double(pointX) / 3.2 - phase))
                    if pointX == 0 {
                        wavePath.move(to: CGPoint(x: pointX, y: pointY))
                    } else {
                        wavePath.addLine(to: CGPoint(x: pointX, y: pointY))
                    }
                }
                graphicsContext.stroke(wavePath, with: .color(accentColor), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
            .frame(width: DS.ChatPanel.statusIndicatorWidthInPoints, height: DS.ChatPanel.statusIndicatorHeightInPoints)
        }
    }
}
