import AVFoundation

@MainActor
enum SpeechAudioSession {
    static func activate() {
        let session = AVAudioSession.sharedInstance()

        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            print("Failed to activate speech audio session: \(error)")
        }
    }

    static func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            print("Failed to deactivate speech audio session: \(error)")
        }
    }
}

// MARK: - Voice Picker

/// Shared voice selection logic that picks the best available voice for a given ReviewItemType.
/// Prioritizes well-known premium/enhanced Chinese voices for natural-sounding speech.
enum SpeechVoicePicker {

    /// Well-known high-quality Chinese voice identifiers (iOS built-in).
    /// Users may need to download these in Settings > Accessibility > Spoken Content > Voices.
    private static let preferredChineseVoiceNames = [
        "Tingting",   // 婷婷 — premium quality, very natural
        "Meijia",     // 美佳 — enhanced quality
        "Lili",       // 莉莉 — enhanced quality
        "Sinji",      // — enhanced quality (zh-HK but also good)
    ]

    private static let preferredEnglishVoiceNames = [
        "Ava",        // Premium
        "Zoe",        // Premium
        "Samantha",   // Enhanced
    ]

    static func voice(for type: ReviewItemType) -> AVSpeechSynthesisVoice? {
        let allVoices = AVSpeechSynthesisVoice.speechVoices()

        switch type {
        case .chineseCharacter, .phrase:
            return bestChineseVoice(from: allVoices)
        case .englishWord, .englishSentence:
            return bestEnglishVoice(from: allVoices)
        }
    }

    private static func bestChineseVoice(from voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        let chineseVoices = voices.filter {
            $0.language.hasPrefix("zh-CN") ||
            $0.language.hasPrefix("zh-Hans")
        }

        // 1. Try to find a preferred voice by name (these are the best sounding ones)
        for name in preferredChineseVoiceNames {
            if let match = chineseVoices.first(where: {
                $0.name.localizedCaseInsensitiveContains(name)
            }) {
                return match
            }
        }

        // 2. Fall back to highest quality available
        if let best = chineseVoices
            .sorted(by: { voiceQualityRank($0) > voiceQualityRank($1) })
            .first {
            return best
        }

        // 3. Last resort
        return AVSpeechSynthesisVoice(language: "zh-CN")
    }

    private static func bestEnglishVoice(from voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        let englishVoices = voices.filter {
            $0.language.hasPrefix("en-US") || $0.language.hasPrefix("en-GB")
        }

        for name in preferredEnglishVoiceNames {
            if let match = englishVoices.first(where: {
                $0.name.localizedCaseInsensitiveContains(name)
            }) {
                return match
            }
        }

        if let best = englishVoices
            .sorted(by: { voiceQualityRank($0) > voiceQualityRank($1) })
            .first {
            return best
        }

        return AVSpeechSynthesisVoice(language: "en-US")
    }

    private static func voiceQualityRank(_ voice: AVSpeechSynthesisVoice) -> Int {
        switch voice.quality {
        case .premium:  return 3
        case .enhanced: return 2
        default:        return 1
        }
    }
}

enum SpeechUtteranceBuilder {
    static func utterances(
        content: String,
        type: ReviewItemType,
        prompt: String? = nil
    ) -> [AVSpeechUtterance] {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return [] }

        var utterances = [
            utterance(
                text: trimmedContent,
                voiceType: type,
                rate: type.isEnglish ? 0.42 : 0.36
            )
        ]

        if type == .englishWord, let chineseText = chinesePrompt(for: trimmedContent, prompt: prompt) {
            utterances.append(
                utterance(
                    text: chineseText,
                    voiceType: .phrase,
                    rate: 0.36
                )
            )
        }

        return utterances
    }

    private static func utterance(
        text: String,
        voiceType: ReviewItemType,
        rate: Float
    ) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = SpeechVoicePicker.voice(for: voiceType)
        utterance.rate = rate
        utterance.pitchMultiplier = 1.0
        return utterance
    }

    private static func chinesePrompt(for content: String, prompt: String?) -> String? {
        let enteredPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !enteredPrompt.isEmpty {
            return enteredPrompt
        }

        let translation = EnglishGlossService.shared.lookup(text: content)?.translation ?? ""
        let trimmedTranslation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTranslation.isEmpty ? nil : trimmedTranslation
    }
}
