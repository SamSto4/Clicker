//
//  ClickyChatPanelUsageView.swift
//  leanring-buddy
//
//  The "usage" tab of the chat panel: for today and for this month, how many questions were asked
//  (spoken and typed, and how many failed), how many dictations, how fast the answers were, the
//  voice characters spoken, and the tokens and an estimated cost per model. The figures come from
//  the two local metrics logs (see `ClickyUsageSupport.swift`), which hold numbers only.
//
//  Every amount is labelled an estimate, and a model that has no price in the table says "price
//  unknown". The panel gives this view its scrolling and its height; the view only lists.
//

import SwiftUI

struct ClickyChatPanelUsageContentView: View {
    @ObservedObject var viewModel: ClickyChatPanelViewModel

    var body: some View {
        if let usageSummary = viewModel.usageSummary {
            VStack(alignment: .leading, spacing: DS.ChatPanel.tabSectionSpacingInPoints) {
                questionsSection(usageSummary)
                modelsSection(usageSummary)
                footnotes(usageSummary)
            }
        } else {
            Text("reading the logs…")
                .font(.system(size: DS.ChatPanel.messageFontSizeInPoints))
                .foregroundColor(DS.Colors.chatPanelSecondaryText)
        }
    }

    // MARK: - Questions, speed, voice

    private func questionsSection(_ usageSummary: ClickyUsageSummary) -> some View {
        let today = usageSummary.today
        let thisMonth = usageSummary.thisMonth
        return VStack(alignment: .leading, spacing: 0) {
            Grid(
                alignment: .leading,
                horizontalSpacing: DS.ChatPanel.usageColumnSpacingInPoints,
                verticalSpacing: DS.ChatPanel.usageRowSpacingInPoints
            ) {
                GridRow {
                    sectionTitle("USAGE")
                    columnTitle("today")
                    columnTitle("this month")
                }
                figureRow("questions asked", todayText: "\(today.questionCount)", monthText: "\(thisMonth.questionCount)")
                figureRow(
                    "spoken · typed",
                    todayText: "\(today.spokenQuestionCount) · \(today.typedQuestionCount)",
                    monthText: "\(thisMonth.spokenQuestionCount) · \(thisMonth.typedQuestionCount)",
                    isDetail: true
                )
                figureRow("failed", todayText: "\(today.failedQuestionCount)", monthText: "\(thisMonth.failedQuestionCount)", isDetail: true)
                figureRow("dictations", todayText: "\(today.dictationCount)", monthText: "\(thisMonth.dictationCount)")
                figureRow(
                    "to first spoken word, median",
                    todayText: ClickyUsageText.durationText(milliseconds: today.medianMillisecondsFromKeyReleaseToFirstSpokenWord),
                    monthText: ClickyUsageText.durationText(milliseconds: thisMonth.medianMillisecondsFromKeyReleaseToFirstSpokenWord)
                )
                figureRow(
                    "to first reply text, typed, median",
                    todayText: ClickyUsageText.durationText(milliseconds: today.medianMillisecondsToFirstReplyTextOfTypedTurns),
                    monthText: ClickyUsageText.durationText(milliseconds: thisMonth.medianMillisecondsToFirstReplyTextOfTypedTurns)
                )
                figureRow(
                    "voice characters spoken",
                    todayText: ClickyUsageText.separatedCountText(today.voiceCharactersSpoken),
                    monthText: ClickyUsageText.separatedCountText(thisMonth.voiceCharactersSpoken)
                )
            }
            Text("cost depends on your ElevenLabs plan")
                .font(.system(size: DS.ChatPanel.footnoteFontSizeInPoints))
                .foregroundColor(DS.Colors.chatPanelTertiaryText)
                .padding(.top, 4)
        }
    }

    // MARK: - Tokens and estimated cost per model

    private func modelsSection(_ usageSummary: ClickyUsageSummary) -> some View {
        // Every model used this month, and any used today that the month's list somehow lacks.
        var modelNames = usageSummary.thisMonth.modelUsages.map(\.modelName)
        for modelUsageOfToday in usageSummary.today.modelUsages where !modelNames.contains(modelUsageOfToday.modelName) {
            modelNames.append(modelUsageOfToday.modelName)
        }
        return VStack(alignment: .leading, spacing: 0) {
            Grid(
                alignment: .leading,
                horizontalSpacing: DS.ChatPanel.usageColumnSpacingInPoints,
                verticalSpacing: DS.ChatPanel.usageRowSpacingInPoints
            ) {
                GridRow {
                    sectionTitle("TOKENS · ESTIMATED COST")
                    columnTitle("today")
                    columnTitle("this month")
                }
                if modelNames.isEmpty && !usageSummary.thisMonth.memoryCompaction.hasAnything {
                    GridRow {
                        Text("no model use logged yet.")
                            .font(.system(size: DS.ChatPanel.messageFontSizeInPoints))
                            .foregroundColor(DS.Colors.chatPanelSecondaryText)
                            .gridCellColumns(3)
                    }
                }
                ForEach(modelNames, id: \.self) { modelName in
                    modelRows(
                        modelName: modelName,
                        todayUsage: usageSummary.today.modelUsages.first { $0.modelName == modelName },
                        monthUsage: usageSummary.thisMonth.modelUsages.first { $0.modelName == modelName }
                    )
                }
                memoriesRows(usageSummary)
            }
        }
    }

    @ViewBuilder
    private func modelRows(modelName: String, todayUsage: ClickyModelUsage?, monthUsage: ClickyModelUsage?) -> some View {
        GridRow {
            Text(modelName)
                .font(.system(size: DS.ChatPanel.rowTitleFontSizeInPoints, weight: .medium))
                .foregroundColor(DS.Colors.chatPanelPrimaryText)
                .padding(.top, DS.ChatPanel.usageModelBlockTopPaddingInPoints)
                .gridCellColumns(3)
        }
        figureRow(
            "tokens in · out",
            todayText: tokensInAndOutText(todayUsage),
            monthText: tokensInAndOutText(monthUsage),
            isDetail: true
        )
        figureRow(
            "cache read · write",
            todayText: cacheReadAndWriteText(todayUsage),
            monthText: cacheReadAndWriteText(monthUsage),
            isDetail: true
        )
        figureRow(
            "estimated cost",
            todayText: costText(todayUsage),
            monthText: costText(monthUsage),
            isDetail: true
        )
    }

    /// The "memories" row (round 16): what compacting finished chats into memory lines used, costed
    /// at the price of the model that does it (Haiku). Its tokens are not in any model's rows above.
    @ViewBuilder
    private func memoriesRows(_ usageSummary: ClickyUsageSummary) -> some View {
        let today = usageSummary.today.memoryCompaction
        let thisMonth = usageSummary.thisMonth.memoryCompaction
        if thisMonth.hasAnything || today.hasAnything {
            GridRow {
                Text("memories")
                    .font(.system(size: DS.ChatPanel.rowTitleFontSizeInPoints, weight: .medium))
                    .foregroundColor(DS.Colors.chatPanelPrimaryText)
                    .padding(.top, DS.ChatPanel.usageModelBlockTopPaddingInPoints)
                    .gridCellColumns(3)
            }
            figureRow(
                "chats compacted · memories kept",
                todayText: "\(today.compactionCount) · \(today.memoriesKeptCount)",
                monthText: "\(thisMonth.compactionCount) · \(thisMonth.memoriesKeptCount)",
                isDetail: true
            )
            figureRow(
                "tokens in · out",
                todayText: "\(ClickyUsageText.compactTokenCountText(today.inputTokens)) · \(ClickyUsageText.compactTokenCountText(today.outputTokens))",
                monthText: "\(ClickyUsageText.compactTokenCountText(thisMonth.inputTokens)) · \(ClickyUsageText.compactTokenCountText(thisMonth.outputTokens))",
                isDetail: true
            )
            figureRow(
                "estimated cost (\(ClickyMemoryCompaction.modelName))",
                todayText: ClickyUsageText.estimatedCostText(dollars: today.estimatedCostInDollars),
                monthText: ClickyUsageText.estimatedCostText(dollars: thisMonth.estimatedCostInDollars),
                isDetail: true
            )
        }
    }

    private func tokensInAndOutText(_ modelUsage: ClickyModelUsage?) -> String {
        guard let modelUsage else { return "–" }
        return "\(ClickyUsageText.compactTokenCountText(modelUsage.inputTokens)) · \(ClickyUsageText.compactTokenCountText(modelUsage.outputTokens))"
    }

    private func cacheReadAndWriteText(_ modelUsage: ClickyModelUsage?) -> String {
        guard let modelUsage else { return "–" }
        return "\(ClickyUsageText.compactTokenCountText(modelUsage.cacheReadTokens)) · \(ClickyUsageText.compactTokenCountText(modelUsage.cacheWriteTokens))"
    }

    private func costText(_ modelUsage: ClickyModelUsage?) -> String {
        guard let modelUsage else { return "–" }
        return ClickyUsageText.estimatedCostText(dollars: modelUsage.estimatedCostInDollars)
    }

    // MARK: - Footnotes

    private func footnotes(_ usageSummary: ClickyUsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let turnFiguresStartDate = usageSummary.turnLogMonthFiguresStartDate {
                footnote("this month's questions count \(ClickyUsageText.sinceDateText(turnFiguresStartDate)): the log keeps only its newest \(ClickyTurnMetricsLog.newestLineCountToKeep) lines.")
            }
            if let dictationFiguresStartDate = usageSummary.dictationLogMonthFiguresStartDate {
                footnote("this month's dictations count \(ClickyUsageText.sinceDateText(dictationFiguresStartDate)): that log is kept short too.")
            }
            if usageSummary.thisMonth.dictationsWithUnknownTokenCountsCount > 0 {
                let unknownCleanupCount = usageSummary.thisMonth.dictationsWithUnknownTokenCountsCount
                footnote(unknownCleanupCount == 1
                    ? "1 dictation cleanup this month has no token count, so it is not in the tokens or the cost."
                    : "\(unknownCleanupCount) dictation cleanups this month have no token count, so they are not in the tokens or the cost.")
            }
            footnote("every amount is an estimate from published list prices (november 2026) and may differ from your bill. a model without a listed price shows its tokens and \"price unknown\".")
            footnote("from the local logs in library/logs/clicky. they hold numbers only, never your words.")
        }
        .padding(.horizontal, DS.ChatPanel.textActionHorizontalPaddingInPoints)
    }

    private func footnote(_ footnoteText: String) -> some View {
        Text(footnoteText)
            .font(.system(size: DS.ChatPanel.footnoteFontSizeInPoints))
            .foregroundColor(DS.Colors.chatPanelTertiaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Grid pieces

    private func sectionTitle(_ titleText: String) -> some View {
        Text(titleText)
            .font(.system(size: DS.ChatPanel.sectionTitleFontSizeInPoints, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(DS.Colors.chatPanelTertiaryText)
    }

    private func columnTitle(_ titleText: String) -> some View {
        Text(titleText)
            .font(.system(size: DS.ChatPanel.rowDetailFontSizeInPoints, weight: .medium))
            .foregroundColor(DS.Colors.chatPanelSecondaryText)
            .frame(width: DS.ChatPanel.usageValueColumnWidthInPoints, alignment: .trailing)
    }

    private func figureRow(_ labelText: String, todayText: String, monthText: String, isDetail: Bool = false) -> some View {
        GridRow {
            Text(labelText)
                .font(.system(size: isDetail ? DS.ChatPanel.rowDetailFontSizeInPoints : DS.ChatPanel.messageFontSizeInPoints))
                .foregroundColor(isDetail ? DS.Colors.chatPanelSecondaryText : DS.Colors.chatPanelPrimaryText)
                .padding(.leading, isDetail ? 10 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
            figureValue(todayText, isDetail: isDetail)
            figureValue(monthText, isDetail: isDetail)
        }
    }

    private func figureValue(_ valueText: String, isDetail: Bool) -> some View {
        Text(valueText)
            .font(.system(size: isDetail ? DS.ChatPanel.rowDetailFontSizeInPoints : DS.ChatPanel.messageFontSizeInPoints, weight: isDetail ? .regular : .medium).monospacedDigit())
            .foregroundColor(isDetail ? DS.Colors.chatPanelSecondaryText : DS.Colors.chatPanelPrimaryText)
            .frame(width: DS.ChatPanel.usageValueColumnWidthInPoints, alignment: .trailing)
    }
}
