import Foundation
import AVFoundation
import Observation

@MainActor
@Observable
final class MediaPlaybackCoordinator {
    private(set) var player = AVPlayer()
    private(set) var currentAsset: MediaLibraryAsset?
    private(set) var isPlaying = false
    private(set) var isManuallyPaused = false
    private(set) var isWaitingForDownload = false
    private(set) var pendingAssetTitle: String?
    private(set) var isBoardManualSession = false
    private(set) var boardManualPlaybackOption: BoardManualPlaybackOption?

    private var playlist: [MediaLibraryAsset] = []
    private var currentIndex = 0
    private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var downloadRetryTask: Task<Void, Never>?
    private var boardManualStopDeadline: Date?
    private var wrapsAtPlaylistEnd = true

    private func normalizedPlaylist(from playlist: [MediaLibraryAsset]) -> [MediaLibraryAsset] {
        playlist
            .filter(\.isIncludedInPlaylist)
            .sorted { lhs, rhs in
                if lhs.playlistOrder == rhs.playlistOrder {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.playlistOrder > rhs.playlistOrder
            }
    }

    var boardManualStatusText: String? {
        guard isBoardManualSession, isPlaying else { return nil }
        return boardManualPlaybackOption?.statusText
    }

    func sync(now: Date, settings: AppSettings?, playlist: [MediaLibraryAsset]) {
        let normalizedPlaylist = normalizedPlaylist(from: playlist)
        let previousPlaylistIDs = self.playlist.map(\.id)
        let normalizedPlaylistIDs = normalizedPlaylist.map(\.id)
        self.playlist = normalizedPlaylist

        if isBoardManualSession {
            if let deadline = boardManualStopDeadline, now >= deadline {
                suspendBoardManualPlayback()
                return
            }

            guard !normalizedPlaylist.isEmpty else {
                stop()
                return
            }

            if isManuallyPaused {
                return
            }

            let currentStillExists = normalizedPlaylist.contains { $0.id == currentAsset?.id }
            if currentAsset == nil || !currentStillExists {
                let restartIndex = min(currentIndex, max(normalizedPlaylist.count - 1, 0))
                startPlayback(at: restartIndex, allowsWrap: wrapsAtPlaylistEnd)
                return
            }

            if !isPlaying, player.currentItem != nil {
                MediaAudioSession.activate()
                player.play()
                isPlaying = true
            }
            return
        }

        guard let settings else {
            stop()
            return
        }

        guard settings.isBoardAutoplayActive(on: now) else {
            stop()
            return
        }

        guard !normalizedPlaylist.isEmpty else {
            stop()
            return
        }

        if isManuallyPaused {
            return
        }

        let needsRestart = normalizedPlaylistIDs != previousPlaylistIDs
            || currentAsset == nil
            || !normalizedPlaylist.contains(where: { $0.id == currentAsset?.id })

        if needsRestart {
            clearBoardManualSession()
            startPlayback(at: 0, allowsWrap: true)
            return
        }

        if !isPlaying {
            MediaAudioSession.activate()
            player.play()
            isPlaying = true
        }
    }

    func toggleManualPlayback(
        playlist: [MediaLibraryAsset],
        option: BoardManualPlaybackOption
    ) {
        let normalizedPlaylist = normalizedPlaylist(from: playlist)
        self.playlist = normalizedPlaylist

        if isWaitingForDownload {
            stop()
            return
        }

        if isPlaying {
            pause()
            return
        }

        if currentAsset != nil, player.currentItem != nil {
            configureBoardManualSession(option: option)
            isManuallyPaused = false
            MediaAudioSession.activate()
            player.play()
            isPlaying = true
            return
        }

        guard !normalizedPlaylist.isEmpty else {
            stop()
            return
        }

        configureBoardManualSession(option: option)
        isManuallyPaused = false
        startPlayback(at: 0, allowsWrap: wrapsAtPlaylistEnd)
    }

    func play(
        asset: MediaLibraryAsset,
        within playlist: [MediaLibraryAsset],
        boardManualOption option: BoardManualPlaybackOption
    ) {
        let normalizedPlaylist = normalizedPlaylist(from: playlist)
        guard !normalizedPlaylist.isEmpty else {
            stop()
            return
        }

        guard let assetIndex = normalizedPlaylist.firstIndex(where: { $0.id == asset.id }) else {
            stop()
            return
        }

        self.playlist = normalizedPlaylist
        configureBoardManualSession(option: option)
        isManuallyPaused = false
        startPlayback(at: assetIndex, allowsWrap: wrapsAtPlaylistEnd)
    }

    func play(asset: MediaLibraryAsset, within playlist: [MediaLibraryAsset]) {
        let normalizedPlaylist = normalizedPlaylist(from: playlist)
        guard !normalizedPlaylist.isEmpty else {
            stop()
            return
        }

        guard let assetIndex = normalizedPlaylist.firstIndex(where: { $0.id == asset.id }) else {
            stop()
            return
        }

        self.playlist = normalizedPlaylist
        clearBoardManualSession()
        isManuallyPaused = false
        startPlayback(at: assetIndex, allowsWrap: true)
    }

    func pause() {
        guard currentAsset != nil else { return }
        player.pause()
        isPlaying = false
        isManuallyPaused = true
        isWaitingForDownload = false
        pendingAssetTitle = nil
    }

    func pauseForTemporaryInterruption() {
        guard currentAsset != nil, isPlaying else { return }
        player.pause()
        isPlaying = false
    }

    func resumeAfterTemporaryInterruption() {
        guard currentAsset != nil,
              player.currentItem != nil,
              !isPlaying,
              !isManuallyPaused,
              !isWaitingForDownload else {
            return
        }

        MediaAudioSession.activate()
        player.play()
        isPlaying = true
    }

    func stop() {
        cancelDownloadRetry()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentAsset = nil
        isPlaying = false
        isManuallyPaused = false
        isWaitingForDownload = false
        pendingAssetTitle = nil
        clearBoardManualSession()

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        MediaAudioSession.deactivate()
    }

    func stopBoardPlaybackByUser() {
        cancelDownloadRetry()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentAsset = nil
        isPlaying = false
        isManuallyPaused = true
        isWaitingForDownload = false
        pendingAssetTitle = nil
        clearBoardManualSession()

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        MediaAudioSession.deactivate()
    }

    private func configureBoardManualSession(option: BoardManualPlaybackOption) {
        isBoardManualSession = true
        boardManualPlaybackOption = option
        wrapsAtPlaylistEnd = option != .untilPlaylistEnds
        boardManualStopDeadline = option.durationMinutes.map {
            Date.now.addingTimeInterval(Double($0 * 60))
        }
    }

    private func clearBoardManualSession() {
        isBoardManualSession = false
        boardManualPlaybackOption = nil
        boardManualStopDeadline = nil
        wrapsAtPlaylistEnd = true
    }

    private func suspendBoardManualPlayback() {
        cancelDownloadRetry()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentAsset = nil
        isPlaying = false
        isManuallyPaused = true
        isWaitingForDownload = false
        pendingAssetTitle = nil
        boardManualStopDeadline = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        MediaAudioSession.deactivate()
    }

    private func startPlayback(at index: Int, attempts: Int = 0, allowsWrap: Bool) {
        guard !playlist.isEmpty else {
            stop()
            return
        }

        guard attempts < playlist.count else {
            stop()
            return
        }

        let asset = playlist[index]
        let availability = MediaLibraryStorage.availability(for: asset.storedFilename)

        guard case let .ready(fileURL) = availability else {
            if case .downloading = availability {
                currentIndex = index
                currentAsset = nil
                isPlaying = false
                isWaitingForDownload = true
                pendingAssetTitle = asset.title
                MediaAudioSession.deactivate()
                waitForDownload(
                    of: asset,
                    at: index,
                    attempts: attempts,
                    allowsWrap: allowsWrap
                )
                return
            }

            guard let nextIndex = nextIndex(after: index, allowsWrap: allowsWrap) else {
                stop()
                return
            }

            startPlayback(at: nextIndex, attempts: attempts + 1, allowsWrap: allowsWrap)
            return
        }

        currentIndex = index
        currentAsset = asset
        pendingAssetTitle = nil
        isWaitingForDownload = false
        downloadRetryTask = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }

        let item = AVPlayerItem(url: fileURL)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.playNext()
            }
        }

        MediaAudioSession.activate()
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        isManuallyPaused = false
    }

    private func waitForDownload(
        of asset: MediaLibraryAsset,
        at index: Int,
        attempts: Int,
        allowsWrap: Bool
    ) {
        cancelDownloadRetry()
        let storedFilename = asset.storedFilename

        downloadRetryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }

                let downloadedFileURL: URL? = await Task.detached(priority: .utility) { () -> URL? in
                    if case let .ready(fileURL) = MediaLibraryStorage.availability(
                        for: storedFilename,
                        requestDownloadIfNeeded: false
                    ) {
                        return fileURL
                    }
                    return nil
                }.value

                guard let self,
                      self.isWaitingForDownload,
                      self.currentIndex == index else {
                    return
                }

                if downloadedFileURL != nil {
                    self.startPlayback(
                        at: index,
                        attempts: attempts,
                        allowsWrap: allowsWrap
                    )
                    return
                }
            }
        }
    }

    private func cancelDownloadRetry() {
        downloadRetryTask?.cancel()
        downloadRetryTask = nil
    }

    private func playNext() {
        guard !playlist.isEmpty else {
            stop()
            return
        }

        guard let nextIndex = nextIndex(after: currentIndex, allowsWrap: wrapsAtPlaylistEnd) else {
            stop()
            return
        }

        startPlayback(at: nextIndex, allowsWrap: wrapsAtPlaylistEnd)
    }

    private func nextIndex(after index: Int, allowsWrap: Bool) -> Int? {
        guard !playlist.isEmpty else { return nil }

        let next = index + 1
        if next < playlist.count {
            return next
        }

        return allowsWrap ? 0 : nil
    }
}

@MainActor
enum MediaAudioSession {
    static func activate() {
        let session = AVAudioSession.sharedInstance()

        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true, options: [])
        } catch {
            print("Failed to activate media audio session: \(error)")
        }
    }

    static func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            print("Failed to deactivate media audio session: \(error)")
        }
    }
}
