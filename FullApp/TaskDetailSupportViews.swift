import SwiftUI
import SwiftData
import UIKit

// MARK: - Task Detail 支撑视图
// 从 TaskDetailView.swift 拆分出的独立子视图，用于打开任务编辑器和快速添加子任务。

struct TaskEditorLoaderView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    let taskID: UUID
    let fallbackTitle: String

    @State private var task: TaskItem?
    @State private var loadTask: Task<Void, Never>?
    @State private var loadFailed = false

    private var canLoad: Bool {
        scenePhase == .active && UIApplication.shared.applicationState == .active
    }

    var body: some View {
        Group {
            if let task {
                AddTaskView(task: task)
            } else if loadFailed {
                ContentUnavailableView("任务不存在", systemImage: "exclamationmark.triangle")
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在打开 \(fallbackTitle)…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemGroupedBackground))
            }
        }
        .navigationTitle("编辑任务")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadTaskAfterNavigationSettles()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                loadTaskAfterNavigationSettles()
            } else {
                loadTask?.cancel()
            }
        }
        .onDisappear {
            loadTask?.cancel()
        }
    }

    private func loadTaskAfterNavigationSettles() {
        loadTask?.cancel()
        guard task == nil else { return }
        guard canLoad else { return }

        loadTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            guard canLoad else { return }

            do {
                var descriptor = FetchDescriptor<TaskItem>(
                    predicate: #Predicate<TaskItem> { $0.id == taskID }
                )
                descriptor.fetchLimit = 1
                task = try modelContext.fetch(descriptor).first
                loadFailed = task == nil
            } catch {
                loadFailed = true
            }
        }
    }
}

struct QuickSubtaskInputView: View {
    let isSaving: Bool
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: String = ""
    @State private var isSubmitting = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "square.and.pencil")
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .frame(width: 40, height: 40)

                TextField("输入子任务标题，输完点下方按钮", text: $draft)
                    .textInputAutocapitalization(.sentences)
                    .focused($isFocused)
                    .submitLabel(.done)
            }

            HStack(spacing: 16) {
                Spacer()

                Button("取消") {
                    isFocused = false
                    onCancel()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .disabled(isSaving || isSubmitting)

                Button {
                    commitIMEAndSave()
                } label: {
                    Text(isSaving ? "正在添加…" : "添加子任务")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray : Color.blue,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(isSaving || isSubmitting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                isFocused = true
            }
        }
        .onSubmit {
            commitIMEAndSave()
        }
        .onChange(of: isSaving) { wasSaving, isSaving in
            if wasSaving && !isSaving {
                isSubmitting = false
            }
        }
    }

    private func commitIMEAndSave() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSaving, !isSubmitting else { return }
        isSubmitting = true

        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            onSave(trimmed)
            draft = ""
        }
    }
}
