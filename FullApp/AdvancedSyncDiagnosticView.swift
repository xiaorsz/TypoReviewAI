import SwiftUI
import SwiftData

struct AdvancedSyncDiagnosticView: View {
    private static let defaultVisibleCloudKitEventCount = 6

    @Environment(\.modelContext) private var modelContext
    @Environment(SyncStatusStore.self) private var syncStatusStore
    @Environment(AppSettingsStore.self) private var settingsStore

    private var serverSyncCoordinator: ServerSyncCoordinator {
        .shared
    }

    var body: some View {
        Form {
            Section {
                diagnosticRow(title: "当前存储", value: syncStatusStore.storageModeTitle)
                diagnosticRow(title: "同步模式", value: syncStatusStore.cloudKitModeText)
                if !serverSyncCoordinator.isEnabled {
                    diagnosticRow(title: "iCloud 账户", value: syncStatusStore.cloudAccountTitle)
                    diagnosticRow(title: "安装线索", value: syncStatusStore.cloudKitEnvironment)
                    diagnosticRow(title: "编译配置", value: syncStatusStore.buildConfiguration)
                    diagnosticRow(title: "容器 ID", value: syncStatusStore.containerIdentifier, monospaced: true)
                }
                diagnosticRow(title: "本地数据", value: syncStatusStore.localDataSummary)
            } header: {
                Text("诊断指标")
            } footer: {
                if serverSyncCoordinator.isEnabled {
                    Text("本地数据是当前设备实际保存的数量，可与下方最近一次服务器下载数量对照。")
                } else {
                    Text("安装收据和编译配置不能证明实际签名的 CloudKit 环境。账户可用也不代表该容器已能同步；请结合区域访问、模型写入和上传／下载事件判断。")
                }
            }

            if serverSyncCoordinator.isEnabled {
                Section {
                    diagnosticRow(
                        title: "服务器状态",
                        value: serverSyncCoordinator.serverStatusText
                    )
                    diagnosticRow(
                        title: "最近下载",
                        value: dateText(serverSyncCoordinator.lastSuccessfulPullAt)
                    )
                    diagnosticRow(
                        title: "最近连通",
                        value: dateText(serverSyncCoordinator.lastSuccessfulConnectionAt)
                    )
                    diagnosticRow(
                        title: "最近上传",
                        value: dateText(serverSyncCoordinator.lastSuccessfulUploadAt)
                    )
                    diagnosticRow(
                        title: "下载内容",
                        value: serverSyncCoordinator.lastPulledDataSummary
                    )

                    if let error = serverSyncCoordinator.lastErrorDescription {
                        Text(error)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }

                    Button {
                        Task {
                            await serverSyncCoordinator.pull(
                                into: modelContext,
                                settingsStore: settingsStore
                            )
                            await syncStatusStore.refresh(using: modelContext, trigger: .manual)
                        }
                    } label: {
                        HStack {
                            Text("立即从服务器同步并检查")
                            Spacer()
                            if serverSyncCoordinator.isSynchronizing {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(serverSyncCoordinator.isSynchronizing)
                } header: {
                    Text("服务器同步")
                } footer: {
                    Text("同步完成后，对比「下载内容」和「本地数据」即可判断数据是否真正写入当前设备。")
                }
            } else {
                Section {
                    Text(syncStatusStore.cloudAccountDetail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if syncStatusStore.isUsingLocalFallback {
                        Text("当前这台设备已经退回本地存储模式，所以它不会和其他设备互相同步。常见原因是 CloudKit schema 没同步到后台，或这台设备当前构建无法初始化 CloudKit。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    if !syncStatusStore.cloudKitInitializationError.isEmpty {
                        Text(syncStatusStore.cloudKitInitializationError)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("详细说明")
                }

                // MARK: - CloudKit Sync Events

                Section {
                    if syncStatusStore.recentCloudKitEvents.isEmpty {
                        Text("还没有捕获到同步事件，请等待 App 自然触发一次同步，或点击下方「强制触发同步」。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(syncStatusStore.recentCloudKitEvents.prefix(Self.defaultVisibleCloudKitEventCount))) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: event.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(event.succeeded ? .green : .red)
                                        .font(.caption)

                                    Text(event.typeName)
                                        .font(.subheadline.weight(.medium))

                                    Spacer()

                                    Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }

                                if let errorDesc = event.errorDescription {
                                    Text(errorDesc)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.red)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    HStack {
                        Text("CloudKit 同步事件")
                        Spacer()
                        Text("最近 \(min(syncStatusStore.recentCloudKitEvents.count, Self.defaultVisibleCloudKitEventCount)) / \(syncStatusStore.recentCloudKitEvents.count) 条")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("默认显示最近 6 条同步事件。红色条目表示同步失败，展开可查看错误详情。需要保持 App 打开才能捕获事件。")
                }

                // MARK: - CloudKit Direct Test

                Section {
                    Button {
                        Task {
                            await syncStatusStore.testCloudKitDirectly()
                        }
                    } label: {
                        HStack {
                            Text("测试 CloudKit 直连")
                            Spacer()
                            if syncStatusStore.isTestingCloudKit {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(syncStatusStore.isTestingCloudKit)

                    if !syncStatusStore.cloudKitDirectTestResult.isEmpty {
                        Text(syncStatusStore.cloudKitDirectTestResult)
                            .font(.caption.monospaced())
                            .foregroundStyle(
                                syncStatusStore.cloudKitDirectTestResult.hasPrefix("❌") ? Color.red : Color.primary
                            )
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("CloudKit 直连测试")
                } footer: {
                    Text("依次检查账户、同步区域，以及 17 类本地模型的测试字段（含 AI 清单字段），并尝试删除测试记录。区域访问失败时不会执行模型写入；仅在具体错误提示记录类型或字段缺失时核查当前环境的 Schema 部署。直连成功仍不代表实际数据同步已完成。")
                }

                // MARK: - Actions

                Section {
                    Button {
                        Task {
                            await syncStatusStore.refresh(using: modelContext, trigger: .manual)
                        }
                    } label: {
                        HStack {
                            Text("重新检查数据同步状态")
                            Spacer()
                            if syncStatusStore.isRefreshing {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(syncStatusStore.isRefreshing)

                    Button {
                        syncStatusStore.triggerForcePush(using: modelContext)
                    } label: {
                        Text("强制触发同步")
                    }

                    Button(role: .destructive) {
                        syncStatusStore.recentCloudKitEvents.removeAll()
                        syncStatusStore.cloudKitDirectTestResult = ""
                    } label: {
                        Text("清除诊断记录")
                    }
                } header: {
                    Text("操作")
                } footer: {
                    Text("\"强制触发同步\"会临时写入并删除一条记录，迫使 CloudKit 发起一次上传和下载周期。")
                }
            }
        }
        .navigationTitle("同步诊断信息")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func diagnosticRow(title: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
            Spacer()
            Text(value)
                .font(monospaced ? .callout.monospaced() : .body)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        }
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "尚无记录" }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}
