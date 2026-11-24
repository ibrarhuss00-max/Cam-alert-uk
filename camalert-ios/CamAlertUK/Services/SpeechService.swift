import Foundation
import AVFoundation

/// Spoken alerts and directions. Uses the "voice prompt" audio mode so music is ducked
/// while it speaks, and it plays through the car speakers when CarPlay is connected.
final class SpeechService: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechService()

    var enabled = true

    private let synthesizer = AVSpeechSynthesizer()
    private var pending = 0

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// `interrupt: true` cuts off whatever is being said (used for camera alerts).
    func say(_ text: String, interrupt: Bool) {
        guard enabled, !text.isEmpty else { return }
        activateSession()
        if interrupt && synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1
        pending += 1
        synthesizer.speak(utterance)
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt,
                                 options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
    }

    private func finishedOne() {
        pending = max(0, pending - 1)
        if pending == 0 {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.finishedOne() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.finishedOne() }
    }
}
