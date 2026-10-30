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
        if needsRecheck { return "按已保存的清单复习；这份旧安排的依据需要重新检查。" }
        return reason.isEmpty ? "已保存复习清单，暂未提供选题依据。" : reason
    }
}

struct ReviewPlanSummaryView: View {
    let title: String
    let subtitle: String
    let rationale: String
    var contents: [String] = []
    @State private var expanded = false

    var body: some View {
        let explanation = ReviewPlanExplanation(rationale)
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "calendar.badge.checkmark")
                .font(.headline)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            if !contents.isEmpty {
                Text(contents.prefix(4).joined(separator: "、") + (contents.count > 4 ? " 等 \(contents.count) 题" : ""))
                    .font(.subheadline).lineLimit(2)
            }
            Text(explanation.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 14) {
                    if !contents.isEmpty {
                        Text("复习内容").font(.subheadline.bold())
                        ForEach(Array(contents.enumerated()), id: \.offset) { index, content in
                            Text("\(index + 1). \(content)").font(.subheadline)
                        }
                    }
                    Text(explanation.needsRecheck ? "需要重新检查" : "选题依据").font(.subheadline.bold())
                    Text(explanation.reason.isEmpty ? "暂未提供选题依据。" : explanation.reason)
                        .font(.subheadline).foregroundStyle(explanation.needsRecheck ? .orange : .primary)
                    if !explanation.tips.isEmpty {
                        Text("记忆提示").font(.subheadline.bold())
                        ForEach(Array(explanation.tips.enumerated()), id: \.offset) { _, tip in
                            Text("• \(tip)").font(.subheadline)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
            } label: {
                Text(expanded ? "收起详情" : (contents.isEmpty ? "查看选题依据" : "查看内容与依据")).font(.subheadline)
            }
            .accessibilityIdentifier("coach.plan.details")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach.plan.summary")
    }
}
