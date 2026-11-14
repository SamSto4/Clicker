//
//  ClickyChatPanelMemoryView.swift
//  leanring-buddy
//
//  The "memory" tab of the chat panel: the facts in the profile, the memories Clicky kept from
//  earlier chats (round 16) and the daily notes, each with a delete that asks "delete this?" in
//  place (never an alert), and a button that opens the notes folder in Finder. The panel gives
//  this view its scrolling and its height; the view only lists.
//
//  Reading and deleting happen in the view model, on background tasks, never on the main thread.
//  This tab adds no way to save anything.
//

import SwiftUI

struct ClickyChatPanelMemoryContentView: View {
    @ObservedObject var viewModel: ClickyChatPanelViewModel

    /// The time the notes' "today 14:30" words are counted to, taken when the view is made.
    private let now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.ChatPanel.tabSectionSpacingInPoints) {
            if let memoryContents = viewModel.memoryContents {
                profileSection(memoryContents)
                memoriesSection(memoryContents)
                notesSection(memoryContents)
            } else {
                Text("reading your notes folder…")
                    .font(.system(size: DS.ChatPanel.messageFontSizeInPoints))
                    .foregroundColor(DS.Colors.chatPanelSecondaryText)
            }

            if let memoryErrorText = viewModel.memoryErrorText {
                Text(memoryErrorText)
                    .font(.system(size: DS.ChatPanel.rowDetailFontSizeInPoints))
                    .foregroundColor(DS.Colors.chatPanelErrorText)
            }

            footer
        }
    }

    // MARK: - Sections

    private func profileSection(_ memoryContents: ClickyMemoryPanelContents) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("PROFILE · \(memoryContents.profileFacts.count) of \(ClickyProfileStore.maximumStoredFactCount) facts")
            if memoryContents.profileFacts.isEmpty {
                emptyHint("no facts yet.")
            } else {
                ForEach(memoryContents.profileFacts, id: \.identifier) { profileFactEntry in
                    ClickyMemoryRowView(
                        viewModel: viewModel,
                        rowIdentifier: profileFactEntry.identifier,
                        detailText: nil,
                        text: profileFactEntry.factText,
                        confirmDeleteAction: { viewModel.confirmDeletingProfileFact(profileFactEntry) }
                    )
                }
            }
        }
    }

    /// The memories Clicky kept from earlier chats, newest first, each with the day of its chat. Between
    /// the profile and the notes, the order they have in the prompt.
    private func memoriesSection(_ memoryContents: ClickyMemoryPanelContents) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("MEMORIES · \(memoryContents.memories.count)")
            if memoryContents.memories.isEmpty {
                emptyHint("no memories yet. clicky keeps up to three short lines when a chat ends.")
            } else {
                ForEach(memoryContents.memories, id: \.rowIdentifier) { memory in
                    ClickyMemoryRowView(
                        viewModel: viewModel,
                        rowIdentifier: memory.rowIdentifier,
                        detailText: ClickyMemoryPanelText.noteDateText(
                            savedAt: memory.createdAt,
                            hasTimeOfDay: false,
                            now: now
                        ),
                        text: memory.text,
                        confirmDeleteAction: { viewModel.confirmDeletingMemory(memory) }
                    )
                }
            }
        }
    }

    private func notesSection(_ memoryContents: ClickyMemoryPanelContents) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("NOTES · \(memoryContents.totalNoteCount)")
            if memoryContents.notes.isEmpty {
                emptyHint("no notes yet.")
            } else {
                ForEach(memoryContents.notes, id: \.identifier) { noteEntry in
                    ClickyMemoryRowView(
                        viewModel: viewModel,
                        rowIdentifier: noteEntry.identifier,
                        detailText: ClickyMemoryPanelText.noteDateText(
                            savedAt: noteEntry.savedAt,
                            hasTimeOfDay: noteEntry.hasTimeOfDay,
                            now: now
                        ),
                        text: noteEntry.text,
                        confirmDeleteAction: { viewModel.confirmDeletingNote(noteEntry) }
                    )
                }
                if memoryContents.totalNoteCount > memoryContents.notes.count {
                    Text("showing the newest \(memoryContents.notes.count) of \(memoryContents.totalNoteCount). older notes are still in the folder.")
                        .font(.system(size: DS.ChatPanel.footnoteFontSizeInPoints))
                        .foregroundColor(DS.Colors.chatPanelTertiaryText)
                        .padding(.horizontal, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
                        .padding(.top, 6)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { viewModel.openNotesFolder() }) {
                Label("open notes folder", systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(ClickyChatTextButtonStyle())
            .accessibilityLabel("open the notes folder in finder")

            Text("profile.md and the daily notes are plain files in that folder, so you can also edit them by hand. memories are kept on this mac in library/application support/clicky/memories, outside icloud.")
                .font(.system(size: DS.ChatPanel.footnoteFontSizeInPoints))
                .foregroundColor(DS.Colors.chatPanelTertiaryText)
                .padding(.horizontal, DS.ChatPanel.textActionHorizontalPaddingInPoints)
        }
    }

    private func sectionTitle(_ titleText: String) -> some View {
        Text(titleText)
            .font(.system(size: DS.ChatPanel.sectionTitleFontSizeInPoints, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(DS.Colors.chatPanelTertiaryText)
            .padding(.horizontal, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
            .padding(.bottom, DS.ChatPanel.tabSectionTitleBottomPaddingInPoints)
    }

    private func emptyHint(_ hintText: String) -> some View {
        Text(hintText)
            .font(.system(size: DS.ChatPanel.messageFontSizeInPoints))
            .foregroundColor(DS.Colors.chatPanelSecondaryText)
            .padding(.horizontal, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
            .padding(.vertical, DS.ChatPanel.memoryRowVerticalPaddingInPoints)
    }
}

// MARK: - A row

/// One fact or note: its words (and, for a note, when it was saved) and a delete that asks first.
private struct ClickyMemoryRowView: View {
    @ObservedObject var viewModel: ClickyChatPanelViewModel
    let rowIdentifier: String
    let detailText: String?
    let text: String
    let confirmDeleteAction: () -> Void

    @State private var isHovered = false

    private var isAskingToConfirmDelete: Bool {
        viewModel.memoryRowAwaitingDeleteConfirmation == rowIdentifier
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let detailText {
                    Text(detailText)
                        .font(.system(size: DS.ChatPanel.rowDetailFontSizeInPoints))
                        .foregroundColor(DS.Colors.chatPanelTertiaryText)
                }
                Text(text)
                    .font(.system(size: DS.ChatPanel.messageFontSizeInPoints))
                    .foregroundColor(DS.Colors.chatPanelPrimaryText)
                    .lineLimit(DS.ChatPanel.memoryRowTextMaximumLineCount)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            deleteControls
        }
        .padding(.horizontal, DS.ChatPanel.memoryRowHorizontalPaddingInPoints)
        .padding(.vertical, DS.ChatPanel.memoryRowVerticalPaddingInPoints)
        .background(
            RoundedRectangle(cornerRadius: DS.ChatPanel.listRowCornerRadiusInPoints, style: .continuous)
                .fill(isHovered || isAskingToConfirmDelete ? DS.Colors.chatPanelRowHoverBackground : Color.clear)
        )
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var deleteControls: some View {
        if isAskingToConfirmDelete {
            HStack(spacing: DS.ChatPanel.memoryRowActionSpacingInPoints) {
                Text("delete this?")
                    .font(.system(size: DS.ChatPanel.textActionFontSizeInPoints))
                    .foregroundColor(DS.Colors.chatPanelSecondaryText)
                Button(action: confirmDeleteAction) {
                    Text("delete")
                }
                .buttonStyle(ClickyChatTextButtonStyle(isDestructive: true))
                .accessibilityLabel("confirm deleting this")
                Button(action: { viewModel.cancelMemoryDeleteConfirmation() }) {
                    Text("cancel")
                }
                .buttonStyle(ClickyChatTextButtonStyle())
            }
        } else {
            Button(action: { viewModel.askToConfirmDeletingMemoryRow(rowIdentifier: rowIdentifier) }) {
                Text("delete")
            }
            .buttonStyle(ClickyChatTextButtonStyle(isDestructive: true))
            .accessibilityLabel("delete this")
        }
    }
}
