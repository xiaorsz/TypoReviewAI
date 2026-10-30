import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct MediaLibraryView: View {
    private struct FileMetadata: Sendable {
        let syncStatusText: String
        let fileSize: Int64
    }

    private struct FileLookup: Sendable {
        let id: UUID
        let storedFilename: String
        let storageScopeRawValue: String
    }

    private struct FileMetadataSnapshot: Sendable {
        let metadataByAssetID: [UUID: FileMetadata]
        let totalFileSizeText: String
    }

    private struct StorageCleanupResult: Sendable {
        let cleanedFileCount: Int
        let releasedByteCount: Int64
        let failureMessages: [String]
    }

    @Environment(MediaLibraryStore.self) private var mediaLibraryStore

    @State private var isImportingFiles = false
    @State private var importAlert: MediaImportAlert?
    @State private var playbackCoordinator = MediaPlaybackCoordinator()
    @State private var renamingAssetID: UUID?
    @State private var titleDraft = ""
    @State private var fileMetadataByAssetID: [UUID: FileMetadata] = [:]
    @State private var totalMediaFileSizeText = "正在统计…"
    @State private var isConfirmingStorageCleanup = false
    @State private var isCleaningStorage = false

    private var mediaAssets: [MediaLibraryAsset] {
        Array(mediaLibraryStore.mediaAssets.reversed())
    }

    private var totalMediaCount: Int {
        mediaLibraryStore.mediaAssets.count
    }

    private var hasICloudMediaAssets: Bool {
        mediaLibraryStore.mediaAssets.contains { $0.storageScope == .iCloud }
    }

    var body: some View {
        Group {
            if mediaAssets.isEmpty {
                ContentUnavailableView {
                    Label("还没有晨读资源", systemImage: "music.note.list")
                } description: {
                    Text("支持导入音频和视频文件。加入播放列表后，看板会在晨读时段按顺序自动播放。")
                } actions: {
                    Button("导入资源") {
                        isImportingFiles = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    Section {
                        librarySummarySection
                    }
                    .listRowBackground(Color.clear)

                    if playbackCoordinator.currentAsset != nil || playbackCoordinator.isWaitingForDownload {
                        Section {
                            previewSection
                        }
                    }

                    Section {
                        ForEach(mediaAssets) { asset in
                            mediaRow(for: asset)
                        }
                        .onMove(perform: moveAssets)
                        .onDelete(perform: deleteAssets)
                    } footer: {
                        Text("拖动右侧把手可以调整播放顺序；关闭“加入播放列表”后，该资源会保留在库里，但晨读时不会自动播放。")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("晨读资源库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    isImportingFiles = true
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                }

                if !mediaAssets.isEmpty {
                    EditButton()
                }
            }
        }
        .fileImporter(
            isPresented: $isImportingFiles,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .confirmationDialog(
            "清理晨读资源占用？",
            isPresented: $isConfirmingStorageCleanup,
            titleVisibility: .visible
        ) {
            Button("清理本机副本", role: .destructive) {
                cleanDownloadedMediaCopies()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会移除已同步到 iCloud 的本机下载副本，不会删除资源或播放列表。当前试听会停止；以后播放时会自动重新下载。")
        }
        .alert(item: $importAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
        .sheet(isPresented: isShowingRenameSheet) {
            renameSheet
        }
        .task(id: mediaAssets) {
            await refreshFileMetadata(for: mediaAssets)
        }
        .onChange(of: playbackCoordinator.currentAsset?.id) { _, _ in
            Task {
                await refreshFileMetadata(for: mediaAssets)
            }
        }
        .onDisappear {
            playbackCoordinator.stop()
        }
    }

    private var librarySummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                summaryCard(
                    title: "资源数量",
                    value: "\(totalMediaCount)",
                    caption: totalMediaCount == 1 ? "共 1 条资源" : "共 \(totalMediaCount) 条资源",
                    icon: "square.stack.3d.up.fill",
                    tint: .blue
                )

                summaryCard(
                    title: "本机占用",
                    value: totalMediaFileSizeText,
                    caption: "已下载到本机的文件",
                    icon: "externaldrive.fill",
                    tint: .green
                )
            }

            Button {
                isConfirmingStorageCleanup = true
            } label: {
                HStack {
                    if isCleaningStorage {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "externaldrive.badge.minus")
                    }
                    Text(isCleaningStorage ? "正在清理…" : "清理本机占用")
                        .fontWeight(.semibold)
                    Spacer()
                    Text("保留 iCloud 文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isCleaningStorage || !hasICloudMediaAssets)

            Text(hasICloudMediaAssets
                ? "仅移除 iCloud 资源的本机副本；再次播放时会自动下载。"
                : "当前没有可从 iCloud 恢复的资源，本机独有文件不会被清理。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
    }

    private func mediaRow(for asset: MediaLibraryAsset) -> some View {
        let isPlaying = self.isPlaying(asset)
        let syncStatus = fileMetadataByAssetID[asset.id]?.syncStatusText ?? "检查中"
        let statusColor = syncStatusColor(for: syncStatus)
        
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                // Media Icon / Thumbnail Placeholder
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill((asset.mediaType == .video ? Color.orange : Color.blue).opacity(0.1))
                    
                    Image(systemName: asset.mediaType.systemImage)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(asset.mediaType == .video ? .orange : .blue)
                        .symbolEffect(.bounce, value: isPlaying)
                }
                .frame(width: 52, height: 52)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(asset.title)
                            .font(.system(.headline, design: .rounded))
                            .lineLimit(1)
                        
                        if isPlaying {
                            Image(systemName: "waveform")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .symbolEffect(.variableColor.iterative.reversing)
                        }
                    }
                    
                    Text(asset.originalFilename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    
                    HStack(spacing: 8) {
                        // Type & Index Badge
                        HStack(spacing: 4) {
                            Image(systemName: asset.mediaType == .video ? "video.fill" : "headphones")
                                .font(.system(size: 8, weight: .bold))
                            Text("#\(asset.playlistOrder + 1)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                        }
                        .foregroundStyle(asset.mediaType == .video ? .orange : .blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((asset.mediaType == .video ? Color.orange : Color.blue).opacity(0.15), in: Capsule())
                        
                        // Storage & Sync Badge
                        HStack(spacing: 4) {
                            Image(systemName: asset.storageScope == .iCloud ? "icloud.fill" : "iphone")
                                .font(.system(size: 8))
                            Text(syncStatus)
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.12), in: Capsule())

                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                                .font(.system(size: 8))
                            Text(importedAtText(for: asset))
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    .padding(.top, 2)
                }
                
                Spacer()
                
                // Active Controls
                HStack(spacing: 10) {
                    Button {
                        startRenaming(asset)
                    } label: {
                        Image(systemName: "pencil.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        handlePreviewTap(for: asset)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(isPlaying ? Color.orange : Color.accentColor)
                                .frame(width: 32, height: 32)
                            
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .shadow(color: (isPlaying ? Color.orange : Color.accentColor).opacity(0.3), radius: 4, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture {
                handlePreviewTap(for: asset)
            }

            HStack {
                Label {
                    Text("加入晨读播放列表")
                        .font(.subheadline)
                        .foregroundStyle(.primary.opacity(0.8))
                } icon: {
                    Image(systemName: asset.isIncludedInPlaylist ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(asset.isIncludedInPlaylist ? .green : .secondary)
                }
                
                Spacer()
                
                Toggle("", isOn: Binding(
                    get: { asset.isIncludedInPlaylist },
                    set: { newValue in
                        do {
                            try mediaLibraryStore.updateInclusion(for: asset.id, isIncludedInPlaylist: newValue)
                        } catch {
                            showError(error, title: "保存失败")
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: .green))
                .scaleEffect(0.8)
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var previewSection: some View {
        if playbackCoordinator.isWaitingForDownload {
            HStack(spacing: 16) {
                ProgressView()
                    .controlSize(.small)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(playbackCoordinator.pendingAssetTitle.map { "正在准备 “\($0)”" } ?? "资源准备中")
                        .font(.subheadline.weight(.bold))
                    
                    Text("文件下载完成后会自动开始播放")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
        } else if let currentAsset = playbackCoordinator.currentAsset {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label {
                        Text("正在试听")
                            .font(.subheadline.weight(.bold))
                    } icon: {
                        Image(systemName: currentAsset.mediaType.systemImage)
                            .foregroundStyle(currentAsset.mediaType == .video ? .orange : .blue)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background((currentAsset.mediaType == .video ? Color.orange : Color.blue).opacity(0.1), in: Capsule())

                    Spacer()

                    Button {
                        playbackCoordinator.stop()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if currentAsset.mediaType == .video {
                    VideoPlayer(player: playbackCoordinator.player)
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                } else {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color.blue.gradient)
                                .frame(width: 44, height: 44)
                            
                            Image(systemName: "waveform")
                                .font(.system(size: 20))
                                .foregroundStyle(.white)
                                .symbolEffect(.variableColor.iterative.reversing)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(currentAsset.title)
                                .font(.headline)
                            Text(currentAsset.originalFilename)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()
                    }
                    .padding(14)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func moveAssets(from source: IndexSet, to destination: Int) {
        do {
            var reorderedAssets = mediaAssets
            reorderedAssets.move(fromOffsets: source, toOffset: destination)
            try mediaLibraryStore.replaceDisplayedOrder(with: reorderedAssets)
        } catch {
            showError(error, title: "调整顺序失败")
        }
    }

    private func deleteAssets(at offsets: IndexSet) {
        do {
            let assetIDs = offsets.map { mediaAssets[$0].id }
            try mediaLibraryStore.deleteAssets(withIDs: assetIDs)
        } catch {
            showError(error, title: "删除失败")
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }

            do {
                try mediaLibraryStore.importFiles(from: urls)
            } catch {
                showError(error, title: "导入失败")
            }
        case .failure(let error):
            guard !isUserCancelled(error) else { return }
            showError(error, title: "导入失败")
        }
    }

    private func isUserCancelled(_ error: Error) -> Bool {
        let nsError = error as NSError
        return error is CancellationError
            || (nsError.domain == NSCocoaErrorDomain && nsError.code == 3072)
    }

    private func showError(_ error: Error, title: String) {
        importAlert = MediaImportAlert(
            title: title,
            message: error.localizedDescription
        )
    }

    private func handlePreviewTap(for asset: MediaLibraryAsset) {
        if isPlaying(asset) {
            playbackCoordinator.pause()
            return
        }

        playbackCoordinator.play(asset: asset, within: mediaAssets)
    }

    private func isPlaying(_ asset: MediaLibraryAsset) -> Bool {
        playbackCoordinator.isPlaying && playbackCoordinator.currentAsset?.id == asset.id
    }

    private var isShowingRenameSheet: Binding<Bool> {
        Binding(
            get: { renamingAssetID != nil },
            set: { isPresented in
                if !isPresented {
                    renamingAssetID = nil
                    titleDraft = ""
                }
            }
        )
    }

    private var renameSheet: some View {
        NavigationStack {
            Form {
                Section("资源标题") {
                    TextField("请输入标题", text: $titleDraft)
                }
            }
            .navigationTitle("修改标题")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        renamingAssetID = nil
                        titleDraft = ""
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        saveTitle()
                    }
                    .disabled(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.height(220)])
    }

    private func startRenaming(_ asset: MediaLibraryAsset) {
        renamingAssetID = asset.id
        titleDraft = asset.title
    }

    private func saveTitle() {
        guard let renamingAssetID else { return }

        do {
            try mediaLibraryStore.updateTitle(for: renamingAssetID, title: titleDraft)
            self.renamingAssetID = nil
            self.titleDraft = ""
        } catch {
            showError(error, title: "保存失败")
        }
    }

    private func syncStatusColor(for syncStatus: String) -> Color {
        switch syncStatus {
        case "已同步":
            return .green
        case "等待下载", "等待同步":
            return .orange
        case "文件缺失":
            return .red
        default:
            return .secondary
        }
    }

    private func refreshFileMetadata(for assets: [MediaLibraryAsset]) async {
        let lookups = assets.map {
            FileLookup(
                id: $0.id,
                storedFilename: $0.storedFilename,
                storageScopeRawValue: $0.storageScopeRawValue
            )
        }

        let snapshot: FileMetadataSnapshot? = await Task.detached(priority: .utility) { () -> FileMetadataSnapshot? in
            var metadataByAssetID: [UUID: FileMetadata] = [:]
            var totalFileSize: Int64 = 0

            for lookup in lookups {
                guard !Task.isCancelled else { return nil }

                let storageScope = MediaStorageScope(rawValue: lookup.storageScopeRawValue) ?? .local
                let fileMetadata = FileMetadata(
                    syncStatusText: MediaLibraryStorage.syncStatusText(
                        for: lookup.storedFilename,
                        storageScope: storageScope
                    ),
                    fileSize: MediaLibraryStorage.fileSize(for: lookup.storedFilename)
                )
                metadataByAssetID[lookup.id] = fileMetadata
                totalFileSize += fileMetadata.fileSize
            }

            return FileMetadataSnapshot(
                metadataByAssetID: metadataByAssetID,
                totalFileSizeText: ByteCountFormatter.string(
                    fromByteCount: totalFileSize,
                    countStyle: .file
                )
            )
        }.value

        guard !Task.isCancelled, let snapshot else { return }
        fileMetadataByAssetID = snapshot.metadataByAssetID
        totalMediaFileSizeText = snapshot.totalFileSizeText
    }

    private func cleanDownloadedMediaCopies() {
        guard !isCleaningStorage else { return }

        let lookups = mediaLibraryStore.mediaAssets
            .filter { $0.storageScope == .iCloud }
            .map {
                FileLookup(
                    id: $0.id,
                    storedFilename: $0.storedFilename,
                    storageScopeRawValue: $0.storageScopeRawValue
                )
            }
        guard !lookups.isEmpty else { return }

        playbackCoordinator.stop()
        isCleaningStorage = true

        Task {
            let result = await Task.detached(priority: .utility) {
                var cleanedFileCount = 0
                var releasedByteCount: Int64 = 0
                var failureMessages: [String] = []

                for lookup in lookups {
                    do {
                        if let releasedBytes = try MediaLibraryStorage.evictDownloadedCopy(
                            for: lookup.storedFilename
                        ) {
                            cleanedFileCount += 1
                            releasedByteCount += releasedBytes
                        }
                    } catch {
                        failureMessages.append(error.localizedDescription)
                    }
                }

                return StorageCleanupResult(
                    cleanedFileCount: cleanedFileCount,
                    releasedByteCount: releasedByteCount,
                    failureMessages: failureMessages
                )
            }.value

            await refreshFileMetadata(for: mediaAssets)
            isCleaningStorage = false
            showStorageCleanupResult(result)
        }
    }

    private func showStorageCleanupResult(_ result: StorageCleanupResult) {
        let releasedSize = ByteCountFormatter.string(
            fromByteCount: result.releasedByteCount,
            countStyle: .file
        )

        if result.cleanedFileCount > 0 {
            var message = "已清理 \(result.cleanedFileCount) 个本机副本，预计释放 \(releasedSize)。\n\n资源仍保留在 iCloud，播放时会自动下载。"
            if !result.failureMessages.isEmpty {
                message += "\n\n另有 \(result.failureMessages.count) 个文件未能清理：\(result.failureMessages[0])"
            }
            importAlert = MediaImportAlert(title: "清理完成", message: message)
        } else if let firstFailure = result.failureMessages.first {
            importAlert = MediaImportAlert(
                title: "清理失败",
                message: "没有文件被清理：\(firstFailure)"
            )
        } else {
            importAlert = MediaImportAlert(
                title: "暂无可清理内容",
                message: "iCloud 资源可能尚未下载，或本机副本已经清理。资源和播放列表没有变化。"
            )
        }
    }

    private func importedAtText(for asset: MediaLibraryAsset) -> String {
        asset.createdAt.formatted(.dateTime.month().day())
    }

    private func summaryCard(
        title: String,
        value: String,
        caption: String,
        icon: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(tint)

            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(tint.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct MediaImportAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
