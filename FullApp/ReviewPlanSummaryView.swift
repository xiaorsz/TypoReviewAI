import SwiftUI

/// Presentation only: never changes the saved selection or invents a reason.
struct ReviewPlanExplanation {
    let reason: String
    let tips: [String]
    let needsRecheck: Bool

    init(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        needsRecheck = ["分页", "题目ID", "错题ID", "错题 ID", "item_ids", "query_history", "upsert_plan"]
            .contains { text.localizedCaseInsensitiveContains($0) }
        if needsRecheck {
            reason = "这份旧安排的选题依据不完整，建议到 AI 教练重新检查后续安排。"
            tips = []
        } else {
            let range = text.range(of: "提示：") ?? text.range(of: "提示:")
            reason = range.map { String(text[..<$0.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) }
                ?? text
            tips = range.map { text[$0.upperBound...].components(separatedBy: CharacterSet(charactersIn: "；;\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } } ?? []
        }
    }

    var summary: String {
        if needsRecheck { return "复习清单已保存，可继续练习。" }
        return reason.isEmpty ? "已保存复习清单，暂未提供选题依据。" : reason
    }
}

struct ReviewPlanSummaryView: View {
    let title: String
    let subtitle: String
    let rationale: String
    var contents: [String] = []
    var offersCoachLink = false
    @State private var showingDetails = false

    var body: some View {
        let explanation = ReviewPlanExplanation(rationale)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(title, systemImage: "calendar.badge.checkmark").font(.headline)
                Spacer(minLength: 0)
                if explanation.needsRecheck {
                    Text("依据待更新").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(subtitle).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            if !contents.isEmpty {
                Text(contents.prefix(3).joined(separator: "、") + (contents.count > 3 ? "…" : ""))
                    .font(.subheadline).lineLimit(1)
            }
            Text(explanation.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Button { showingDetails = true } label: {
                    HStack(spacing: 4) {
                        Text(contents.isEmpty ? "查看选题依据" : "查看题单与依据")
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    }
                    .frame(minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("coach.plan.details")
                Spacer(minLength: 12)
                if offersCoachLink && explanation.needsRecheck {
                    NavigationLink("检查安排") { AICoachView() }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("coach.plan.recheck")
                }
            }
            .font(.subheadline).buttonStyle(.plain).foregroundStyle(Color.accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach.plan.summary")
        .sheet(isPresented: $showingDetails) {
            ReviewPlanDetailView(title: title, subtitle: subtitle, rationale: rationale,
                                 contents: contents, offersCoachLink: offersCoachLink)
        }
    }
}

private struct ReviewPlanDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let subtitle: String
    let rationale: String
    let contents: [String]
    let offersCoachLink: Bool

    var body: some View {
        let explanation = ReviewPlanExplanation(rationale)
        NavigationStack {
            List {
                Section {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    if explanation.needsRecheck {
                        Label("选题依据待更新，当前题单可继续使用。", systemImage: "info.circle")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if !contents.isEmpty {
                    Section("复习内容 · \(contents.count) 题") {
                        ForEach(Array(contents.enumerated()), id: \.offset) { index, content in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                                    .frame(minWidth: 22, alignment: .trailing)
                                Text(content).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                Section(explanation.needsRecheck ? "需要重新检查" : "选题依据") {
                    Text(explanation.reason.isEmpty ? "暂未提供选题依据。" : explanation.reason)
                        .font(.subheadline)
                    if offersCoachLink && explanation.needsRecheck {
                        NavigationLink("到 AI 教练检查安排") { AICoachView() }
                    }
                }
                if !explanation.tips.isEmpty {
                    Section("记忆提示") {
                        ForEach(Array(explanation.tips.enumerated()), id: \.offset) { _, tip in Text(tip) }
                    }
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("coach.plan.close")
                }
            }
        }
    }
}
