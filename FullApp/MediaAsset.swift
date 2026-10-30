import Foundation
import SwiftData
import UniformTypeIdentifiers

enum MediaAssetType: String, Codable, CaseIterable, Identifiable {
    case audio = "音频"
    case video = "视频"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .audio:
            return "waveform"
        case .video:
            return "play.rectangle.fill"
        }
    }

    static func detect(from url: URL) -> MediaAssetType {
        if let contentType = UTType(filenameExtension: url.pathExtension) {
            if contentType.conforms(to: .movie) || contentType.conforms(to: .video) {
                return .video
            }
        }
        return .audio
    }
}

enum MediaStorageScope: String, Codable, CaseIterable, Identifiable {
    case iCloud = "iCloud"
    case local = "本机"

    var id: String { rawValue }
}

// Kept in the main SwiftData schema only to preserve compatibility with
// historical CloudKit/CoreData transactions from older builds.
@Model
final class MediaAsset {
    var id: UUID = UUID()
    var title: String = ""
    var originalFilename: String = ""
    var storedFilename: String = ""
    var mediaTypeRawValue: String = MediaAssetType.audio.rawValue
    var storageScopeRawValue: String = MediaStorageScope.local.rawValue
    var playlistOrder: Int = 0
    var isIncludedInPlaylist: Bool = true
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(
        id: UUID = UUID(),
        title: String = "",
        originalFilename: String = "",
        storedFilename: String = "",
        mediaTypeRawValue: String = MediaAssetType.audio.rawValue,
        storageScopeRawValue: String = MediaStorageScope.local.rawValue,
        playlistOrder: Int = 0,
        isIncludedInPlaylist: Bool = true,
        createdAt: Date = Date.now,
        updatedAt: Date = Date.now
    ) {
        self.id = id
        self.title = title
        self.originalFilename = originalFilename
        self.storedFilename = storedFilename
        self.mediaTypeRawValue = mediaTypeRawValue
        self.storageScopeRawValue = storageScopeRawValue
        self.playlistOrder = playlistOrder
        self.isIncludedInPlaylist = isIncludedInPlaylist
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct MediaLibraryAsset: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var originalFilename: String
    var storedFilename: String
    var mediaTypeRawValue: String
    var storageScopeRawValue: String
    var playlistOrder: Int
    var isIncludedInPlaylist: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        originalFilename: String,
        storedFilename: String,
        mediaType: MediaAssetType,
        storageScope: MediaStorageScope = .local,
        playlistOrder: Int = 0,
        isIncludedInPlaylist: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.originalFilename = originalFilename
        self.storedFilename = storedFilename
        self.mediaTypeRawValue = mediaType.rawValue
        self.storageScopeRawValue = storageScope.rawValue
        self.playlistOrder = playlistOrder
        self.isIncludedInPlaylist = isIncludedInPlaylist
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var mediaType: MediaAssetType {
        get { MediaAssetType(rawValue: mediaTypeRawValue) ?? .audio }
        set { mediaTypeRawValue = newValue.rawValue }
    }

    var storageScope: MediaStorageScope {
        get { MediaStorageScope(rawValue: storageScopeRawValue) ?? .local }
        set { storageScopeRawValue = newValue.rawValue }
    }

    var fileURL: URL {
        MediaLibraryStorage.fileURL(for: storedFilename)
    }
}
