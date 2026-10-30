import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class MediaLibraryStore {
    private struct MetadataDocument: Codable {
        static let currentVersion = 1

        var version: Int
        var assets: [MediaLibraryAsset]

        init(version: Int = currentVersion, assets: [MediaLibraryAsset]) {
            self.version = version
            self.assets = assets
        }
    }

    private(set) var mediaAssets: [MediaLibraryAsset] = []
    private(set) var lastErrorMessage: String?
    private var metadataChangeObserver: MediaLibraryMetadataChangeObserver?

    func startObservingChangesIfNeeded() {
        guard metadataChangeObserver == nil else { return }
        metadataChangeObserver = MediaLibraryMetadataChangeObserver { [weak self] in
            self?.reload()
        }
        metadataChangeObserver?.start()
    }

    func reload() {
        do {
            let assets = try loadAssets()
            mediaAssets = normalizePlaylistOrder(for: assets)
            lastErrorMessage = nil
        } catch {
            mediaAssets = []
            lastErrorMessage = error.localizedDescription
        }
    }

    func importFiles(from urls: [URL]) throws {
        var importedAssets = mediaAssets
        var nextOrder = (importedAssets.map(\.playlistOrder).max() ?? -1) + 1

        for url in urls {
            let granted = url.startAccessingSecurityScopedResource()
            defer {
                if granted {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let importedFile = try MediaLibraryStorage.importFile(from: url)
            let asset = MediaLibraryAsset(
                title: url.deletingPathExtension().lastPathComponent,
                originalFilename: url.lastPathComponent,
                storedFilename: importedFile.storedFilename,
                mediaType: MediaAssetType.detect(from: url),
                storageScope: importedFile.storageScope,
                playlistOrder: nextOrder
            )
            importedAssets.append(asset)
            nextOrder += 1
        }

        try overwrite(with: importedAssets)
    }

    func updateInclusion(for assetID: UUID, isIncludedInPlaylist: Bool) throws {
        guard let index = mediaAssets.firstIndex(where: { $0.id == assetID }) else { return }
        mediaAssets[index].isIncludedInPlaylist = isIncludedInPlaylist
        mediaAssets[index].updatedAt = .now
        try persistCurrentAssets()
    }

    func updateTitle(for assetID: UUID, title: String) throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        guard let index = mediaAssets.firstIndex(where: { $0.id == assetID }) else { return }

        mediaAssets[index].title = trimmedTitle
        mediaAssets[index].updatedAt = .now
        try persistCurrentAssets()
    }

    func moveAssets(from source: IndexSet, to destination: Int) throws {
        var reorderedAssets = mediaAssets
        reorderedAssets.move(fromOffsets: source, toOffset: destination)
        try overwrite(with: reorderedAssets)
    }

    func replaceDisplayedOrder(with displayedAssets: [MediaLibraryAsset]) throws {
        try overwrite(with: Array(displayedAssets.reversed()))
    }

    func deleteAssets(at offsets: IndexSet) throws {
        let deletedAssets = offsets.map { mediaAssets[$0] }
        deletedAssets.forEach { MediaLibraryStorage.deleteFile(named: $0.storedFilename) }

        let remainingAssets = mediaAssets.enumerated().compactMap { index, asset in
            offsets.contains(index) ? nil : asset
        }

        try overwrite(with: remainingAssets)
    }

    func deleteAssets(withIDs assetIDs: [UUID]) throws {
        let deletedAssets = mediaAssets.filter { assetIDs.contains($0.id) }
        deletedAssets.forEach { MediaLibraryStorage.deleteFile(named: $0.storedFilename) }

        let remainingAssets = mediaAssets.filter { !assetIDs.contains($0.id) }
        try overwrite(with: remainingAssets)
    }

    func replaceAll(with assets: [MediaLibraryAsset]) throws {
        try overwrite(with: assets)
    }

    func snapshots() -> [MediaLibraryAsset] {
        mediaAssets
    }

    private func loadAssets() throws -> [MediaLibraryAsset] {
        let preferredMetadataURL = try? MediaLibraryStorage.preferredMetadataURL().fileURL
        var preferredCandidateFailed = false
        var lastReadError: Error?

        for url in MediaLibraryStorage.metadataCandidateURLs() where FileManager.default.fileExists(atPath: url.path) {
            MediaLibraryStorage.startDownloadingIfNeeded(at: url)

            do {
                let data = try Data(contentsOf: url)
                let document = try Self.makeDecoder().decode(MetadataDocument.self, from: data)

                if let preferredMetadataURL,
                   preferredMetadataURL.path != url.path,
                   !preferredCandidateFailed {
                    try write(document, to: preferredMetadataURL)
                }

                return document.assets
            } catch {
                lastReadError = error
                if preferredMetadataURL?.path == url.path {
                    preferredCandidateFailed = true
                }
                continue
            }
        }

        if let lastReadError {
            throw lastReadError
        }

        return []
    }

    private func overwrite(with assets: [MediaLibraryAsset]) throws {
        mediaAssets = normalizePlaylistOrder(for: assets)
        try persistCurrentAssets()
    }

    private func persistCurrentAssets() throws {
        let document = MetadataDocument(assets: mediaAssets)
        let destination = try MediaLibraryStorage.preferredMetadataURL().fileURL
        try write(document, to: destination)
        lastErrorMessage = nil
    }

    private func write(_ document: MetadataDocument, to url: URL) throws {
        let data = try Self.makeEncoder().encode(document)
        try data.write(to: url, options: .atomic)
    }

    private func normalizePlaylistOrder(for assets: [MediaLibraryAsset]) -> [MediaLibraryAsset] {
        let sortedAssets = assets.sorted { lhs, rhs in
            if lhs.playlistOrder == rhs.playlistOrder {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.playlistOrder < rhs.playlistOrder
        }

        return sortedAssets.enumerated().map { index, asset in
            var normalizedAsset = asset
            normalizedAsset.playlistOrder = index
            return normalizedAsset
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private final class MediaLibraryMetadataChangeObserver {
    private let query = NSMetadataQuery()
    private let onChange: @MainActor () -> Void
    private var observers: [NSObjectProtocol] = []

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(
            format: "%K == %@",
            NSMetadataItemFSNameKey,
            MediaLibraryStorage.metadataFilename
        )
    }

    func start() {
        guard observers.isEmpty else { return }

        let notificationCenter = NotificationCenter.default
        observers = [
            notificationCenter.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: .main
            ) { [weak self] _ in
                self?.handleMetadataChange()
            },
            notificationCenter.addObserver(
                forName: .NSMetadataQueryDidUpdate,
                object: query,
                queue: .main
            ) { [weak self] _ in
                self?.handleMetadataChange()
            }
        ]

        query.start()
    }

    private func handleMetadataChange() {
        query.disableUpdates()
        defer { query.enableUpdates() }

        Task { @MainActor in
            onChange()
        }
    }

    deinit {
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
