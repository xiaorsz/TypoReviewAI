import SwiftUI
import UniformTypeIdentifiers
import CoachCore

struct SettingsView: View {
    @Environment(LabStore.self) private var store
    @Environment(CoachAgent.self) private var agent
    @State private var configuration = CoachConfiguration()
    @State private var apiKey = ""
    @State private var message: String?
    @State private var importing = false
    @State private var readingFile = false
    @State private var preview: ImportPreview?
    @State private var showImportConfirmation = false
    @State private var showResetConfirmation = false
    @State private var showKeyDeleteConfirmation = false
    var body: some View {
        Form {
            Section {
                Label("听写 AI 教练 · 独立实验版", systemImage: "sparkles").font(.headline)
                Text("本机独立存储，通过备份文件复制学习数据。") .font(.subheadline).foregroundStyle(.secondary)
                if let date = store.state.sourceExportedAt { Text("来源备份：\(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                TextField("孩子姓名（可选）", text: $configuration.childName)
                Picker("练习科目", selection: $configuration.subject) { ForEach(Subject.allCases) { Text($0.title).tag($0) } }
                Stepper("每日 AI 题量上限：\(configuration.dailyLimit)", value: $configuration.dailyLimit, in: 1...30)
                Toggle("授权教练自动安排与调整", isOn: $configuration.isEnabled)
                Button(configuration.isEnabled ? "保存设置并授权教练" : "保存设置（暂停教练）") {
                    do {
                        if configuration.isEnabled {
                            guard try !LabKeychain.load().isEmpty else { throw LabError.invalid("请先保存实验版 API Key，再启用教练。") }
                        }
                        agent.cancel(); try store.configure(configuration); message = "教练设置已保存。"
                    } catch { message = error.localizedDescription }
                }
                if store.state.configuration.isEnabled {
                    Button("立即暂停教练", role: .destructive) {
                        do {
                            agent.cancel(); var paused = store.state.configuration; paused.isEnabled = false
                            try store.configure(paused); configuration = paused
                        } catch { message = error.localizedDescription }
                    }
                }
            } header: { Text("练习目标与授权") } footer: {
                Text("授权后，在打开应用或提交新判定时，教练可在科目和题量范围内自动安排练习。孩子用纸笔作答，家长确认对错。")
            }
            Section {
                SecureField("DeepSeek API Key", text: $apiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("模型", selection: $configuration.model) {
                    Text("DeepSeek Flash").tag("deepseek-flash")
                    Text("DeepSeek V4 Pro").tag("deepseek-v4-pro")
                }
                Button("保存 API Key") {
                    do { agent.cancel(); try LabKeychain.save(apiKey); message = "API Key 已保存到实验版的本机钥匙串。" }
                    catch { message = error.localizedDescription }
                }
                Button("清除实验版 API Key", role: .destructive) { showKeyDeleteConfirmation = true }
            } header: { Text("AI 接入") } footer: {
                Text("Key 仅保存在本机，不通过 iCloud 同步。启用教练后，将向 DeepSeek 发送所选科目的题目、练习安排和学习记录用于规划；调用费用由该 Key 的账户承担。")
            }
            Section {
                Button {
                    importing = true
                } label: { Label(readingFile ? "正在读取备份…" : "导入听写复习本备份", systemImage: "square.and.arrow.down") }
                    .disabled(agent.isRunning || readingFile)
                Text("在原 App 的设置中导出 JSON 备份，再从这里选择文件。支持 v1–v5，导入题库、复习历史和听写判定，其他内容跳过。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("清空实验数据", role: .destructive) { showResetConfirmation = true }.disabled(agent.isRunning || readingFile)
            } header: { Text("实验数据") } footer: { Text("导入及清空仅作用于本实验版。API Key 单独管理。") }
            Section {
                Text("家庭订阅是待验证方向。当前版本不提供支付，也不保证学习效果。") .font(.caption).foregroundStyle(.secondary)
                LabeledContent("应用标识", value: "cc.xiaorsz.dictation-coach-lab").font(.caption)
            }
        }
        .navigationTitle("设置")
        .onAppear { configuration = store.state.configuration; do { apiKey = try LabKeychain.load() } catch { message = error.localizedDescription } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { readBackup(url) }
            case .failure(let error): message = error.localizedDescription
            }
        }
        .alert("导入备份副本", isPresented: $showImportConfirmation) {
            Button("取消", role: .cancel) { preview = nil }
            Button("替换实验数据", role: .destructive) {
                guard let preview else { return }
                do {
                    agent.cancel(); try store.replace(with: preview); configuration = store.state.configuration
                    message = "导入完成。\n\(preview.summary.replacingOccurrences(of: "可导入", with: "已导入").replacingOccurrences(of: "将跳过", with: "已跳过"))\n请检查科目和题量后重新授权教练。"
                } catch { message = error.localizedDescription }
                self.preview = nil
            }
        } message: {
            if let preview { Text("备份 v\(preview.version) · \(preview.exportedAt.formatted(date: .abbreviated, time: .shortened))\n\(preview.summary)\n\n将替换实验版内现有数据和计划。源备份文件保持原样。") }
        }
        .confirmationDialog("清空实验版的全部题库、记录和计划？", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("清空实验数据", role: .destructive) {
                do { agent.cancel(); try store.reset(); configuration = store.state.configuration; message = "实验数据已清空。" }
                catch { message = error.localizedDescription }
            }
        }
        .confirmationDialog("清除实验版 API Key 并暂停教练？", isPresented: $showKeyDeleteConfirmation, titleVisibility: .visible) {
            Button("清除 Key", role: .destructive) {
                do {
                    agent.cancel(); try LabKeychain.delete(); apiKey = ""
                    var paused = store.state.configuration; paused.isEnabled = false; try store.configure(paused); configuration = paused
                } catch { message = error.localizedDescription }
            }
        }
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("知道了", role: .cancel) {} } message: { Text(message ?? "") }
    }
    private func readBackup(_ url: URL) {
        readingFile = true
        Task {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() }; readingFile = false }
            do {
                let parsed = try await Task.detached(priority: .userInitiated) {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 50 * 1024 * 1024 else { throw LabError.invalid("备份超过 50 MB。") }
                    return try BackupImporter.preview(Data(contentsOf: url))
                }.value
                preview = parsed; showImportConfirmation = true
            } catch { message = "备份未导入：\(error.localizedDescription)" }
        }
    }
}
