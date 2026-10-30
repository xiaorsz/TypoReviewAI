import SwiftUI

/// Reuse the app's semantic colors; only the classroom layout is distinctive.
/// Decorative marks are hidden from accessibility; real progress stays textual.
enum WordLessonPalette {
    static let ink = Color.primary
    static let muted = Color.secondary
    static let background = Color(uiColor: .systemGroupedBackground)
    static let paper = Color(uiColor: .secondarySystemGroupedBackground)
    static let soft = Color(uiColor: .tertiarySystemGroupedBackground)
    static let highlight = Color.accentColor.opacity(0.08)
    static let accent = Color.accentColor
    static let onAccent = Color.white
    static let line = Color(uiColor: .separator).opacity(0.25)
}

struct WordLessonSurface: ViewModifier {
    var tint: Color = WordLessonPalette.paper
    func body(content: Content) -> some View {
        content.padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(WordLessonPalette.line.opacity(0.65), lineWidth: 1))
    }
}

struct WordLessonButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(WordLessonPalette.onAccent)
            .padding(.horizontal, 22).padding(.vertical, 18)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(WordLessonPalette.accent, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct WordLessonActionLabel: View {
    let title: String
    var symbol = "arrow.right"
    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            Image(systemName: symbol).font(.body.weight(.semibold))
        }
    }
}

/// A little bookmark character, drawn in SwiftUI so it scales without raster assets.
struct WordLessonBook: View {
    var celebrating = false
    var body: some View {
        ZStack {
            Circle().fill(WordLessonPalette.highlight).frame(width: 100, height: 100).offset(x: 6, y: 5)
            RoundedRectangle(cornerRadius: 13).fill(WordLessonPalette.soft)
                .frame(width: 70, height: 86).rotationEffect(.degrees(-12)).offset(x: -8, y: 3)
            RoundedRectangle(cornerRadius: 13).fill(WordLessonPalette.paper)
                .overlay(alignment: .leading) { Rectangle().fill(WordLessonPalette.accent.opacity(0.15)).frame(width: 9).padding(.vertical, 12) }
                .overlay {
                    VStack(spacing: 10) {
                        HStack(spacing: 15) {
                            Capsule().frame(width: 4, height: celebrating ? 4 : 7)
                            Capsule().frame(width: 4, height: celebrating ? 4 : 7)
                        }
                        Path { path in
                            path.move(to: CGPoint(x: 1, y: 1))
                            path.addQuadCurve(to: CGPoint(x: 17, y: 1), control: CGPoint(x: 9, y: 12))
                        }
                        .stroke(WordLessonPalette.accent, style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                        .frame(width: 18, height: 9)
                    }.foregroundStyle(WordLessonPalette.accent).padding(.top, 10)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "bookmark.fill").font(.system(size: 23))
                        .foregroundStyle(WordLessonPalette.accent).offset(x: -9, y: -3)
                }
                .frame(width: 70, height: 86).rotationEffect(.degrees(8))
            Image(systemName: "sparkle").font(.system(size: 22)).foregroundStyle(WordLessonPalette.accent)
                .offset(x: 50, y: -44)
            Circle().fill(WordLessonPalette.accent.opacity(0.35)).frame(width: 5, height: 5).offset(x: -49, y: 31)
        }
        .frame(width: 126, height: 126).accessibilityHidden(true)
    }
}

/// Tags wrap by their measured width, including larger accessibility text.
struct WordLessonFlow: Layout {
    var spacing: CGFloat = 10
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? 600).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(subviews, width: bounds.width)
        for (index, point) in layout.origins.enumerated() {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                  anchor: .topLeading, proposal: ProposedViewSize(size))
        }
    }
    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        let width = max(1, width)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var origins: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y)); x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), origins)
    }
}

struct WordLessonTag: View {
    let text: String
    var marked = false
    var body: some View {
        HStack(spacing: 6) {
            if marked { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
            Text(text).font(.system(.body, design: .rounded, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(WordLessonPalette.paper, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(WordLessonPalette.line, lineWidth: 1))
    }
}

struct WordLessonExplanation: View {
    let meaning: String
    let structure: String
    let example: String
    let translation: String
    var speech: WordLessonSpeech? = nil
    var speechScope = ""
    var speechLanguage: WordLessonSpeechLanguage = .chinese
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("是什么意思").font(.system(.caption, design: .rounded, weight: .medium)).foregroundStyle(WordLessonPalette.muted)
                Text(meaning).font(.system(.title2, design: .rounded, weight: .semibold)).lineSpacing(4)
            }
            if !structure.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("组成与记忆", systemImage: "pencil.tip")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(WordLessonPalette.accent)
                    Text(structure).font(.body).foregroundStyle(WordLessonPalette.ink.opacity(0.82)).lineSpacing(4)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(WordLessonPalette.highlight, in: RoundedRectangle(cornerRadius: 16))
            }
            if !example.isEmpty {
                HStack(alignment: .top, spacing: 14) {
                    RoundedRectangle(cornerRadius: 2).fill(WordLessonPalette.accent.opacity(0.35)).frame(width: 3)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("放进句子里").font(.system(.caption, design: .rounded, weight: .medium)).foregroundStyle(WordLessonPalette.muted)
                        HStack(alignment: .top, spacing: 8) {
                            Text(example).font(.body).lineSpacing(5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("targeted.example.text")
                            if let speech {
                                WordLessonReadButton(speech: speech, key: speechScope + ".example", title: "例句", text: example,
                                    language: speechLanguage, identifier: "targeted.speech.example")
                            }
                        }
                        if !translation.isEmpty {
                            HStack(alignment: .top, spacing: 4) {
                                Text(translation).font(.subheadline).foregroundStyle(WordLessonPalette.muted).lineSpacing(4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let speech {
                                    WordLessonReadButton(speech: speech, key: speechScope + ".translation", title: "中文翻译", text: translation,
                                        language: .chinese, identifier: "targeted.speech.translation")
                                }
                            }
                        }
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct WordLessonReadButton: View {
    @ObservedObject var speech: WordLessonSpeech
    let key: String
    let title: String
    let text: String
    let language: WordLessonSpeechLanguage
    let identifier: String
    private var selected: Bool { speech.activeKey == key && speech.phase != .idle }
    private var action: String { selected ? (speech.phase == .paused ? "继续" : "暂停") : "朗读" }
    var body: some View {
        Button { speech.toggle(key: key, title: title, text: text, language: language) } label: {
            // Reserve the largest symbol, including Dynamic Type, so playback
            // changes stay in place without moving the adjacent word or sentence.
            ZStack {
                Image(systemName: "speaker.wave.2").hidden()
                Image(systemName: "pause.fill").hidden()
                Image(systemName: "play.fill").hidden()
                Image(systemName: selected ? (speech.phase == .paused ? "play.fill" : "pause.fill") : "speaker.wave.2")
            }
                .fixedSize(horizontal: true, vertical: true)
                .font(.body.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .background(selected ? WordLessonPalette.highlight : .clear, in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize(horizontal: true, vertical: true)
        .contentShape(Rectangle()).foregroundStyle(WordLessonPalette.accent)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel((action == "朗读" ? "朗读" : action + "朗读") + title)
        .accessibilityValue(selected ? (speech.phase == .paused ? "已暂停" : "正在朗读") : "未朗读")
        .accessibilityIdentifier(identifier)
    }
}

struct WordLessonSpeechStatus: View {
    @ObservedObject var speech: WordLessonSpeech
    private var active: Bool { speech.phase != .idle }
    private var message: String {
        if let error = speech.error { return error }
        return active ? (speech.phase == .paused ? "已暂停 · " : "正在朗读 · ") + speech.title : ""
    }
    var body: some View {
        // Stay in the layout when idle; inserting/removing this row inside the
        // ScrollView moves the lesson and can also change the scroll offset.
        HStack(spacing: 12) {
            ZStack(alignment: .trailing) {
                Text(" ").lineLimit(2, reservesSpace: true).hidden()
                Text(message).lineLimit(2)
                    .accessibilityIdentifier("targeted.speech.status")
            }
            .font(.caption).foregroundStyle(WordLessonPalette.muted)
            .frame(maxWidth: .infinity, alignment: .trailing)
            if active { stopControl } else { stopControl.hidden() }
        }
    }
    private var stopControl: some View {
        Button("停止", systemImage: "stop.fill") { speech.stop() }
            .labelStyle(.iconOnly).font(.caption)
            .frame(minWidth: 44, minHeight: 44).fixedSize(horizontal: true, vertical: true)
            .accessibilityLabel("停止朗读").accessibilityIdentifier("targeted.speech.stop")
    }
}
