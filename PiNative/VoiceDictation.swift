import AVFoundation
import Foundation
import Speech
import SwiftUI

/// Lifecycle of the composer's dictation control, exposed for the microphone
/// button and status rendering.
enum VoiceDictationState: Equatable {
    case idle
    case starting
    case recording
}

/// Pure transcript state for one dictation session.
///
/// The controller feeds recognizer callbacks into `apply`, and the composer
/// reads `composedDraft`. All draft-composition rules live here so they can be
/// unit tested without a microphone or the Speech framework.
struct DictationTranscriptState: Equatable {
    /// The composer draft captured when dictation started, with trailing
    /// whitespace stripped once up front. Dictation text is always appended
    /// after it, so this is recomputed per partial result without re-trimming.
    private let trimmedBase: String
    private(set) var finalizedText = ""
    private(set) var interimText = ""

    init(baseDraft: String) {
        var base = baseDraft
        while let last = base.last, last.isWhitespace {
            base.removeLast()
        }
        trimmedBase = base
    }

    /// The draft the composer should display: the pre-recording draft joined
    /// to the finalized and in-flight dictation text with single spaces.
    var composedDraft: String {
        var segments: [String] = []
        if !trimmedBase.isEmpty { segments.append(trimmedBase) }
        for liveText in [finalizedText, interimText] {
            let trimmed = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { segments.append(trimmed) }
        }
        return segments.joined(separator: " ")
    }

    /// Feeds one cumulative recognizer result. Final results commit the whole
    /// transcript; partial results keep only the portion that extends the
    /// already committed text final and treat the rest as in-flight. If the
    /// recognizer revises previously committed text, everything falls back to
    /// in-flight rather than duplicating words.
    mutating func apply(cumulativeTranscript: String, isFinal: Bool) {
        if isFinal {
            finalizedText = cumulativeTranscript
            interimText = ""
        } else if cumulativeTranscript.hasPrefix(finalizedText) {
            interimText = String(cumulativeTranscript.dropFirst(finalizedText.count))
        } else {
            finalizedText = ""
            interimText = cumulativeTranscript
        }
    }
}

/// Drives native on-device speech recognition for the chat composer.
///
/// Capture uses `AVAudioEngine` and `SFSpeechRecognizer` with
/// `requiresOnDeviceRecognition` enabled, so audio and transcripts never leave
/// the device. Draft composition is delegated to `DictationTranscriptState`
/// and published through `liveDraft`, which the composer merges into its draft
/// binding.
@MainActor
final class VoiceDictationController: NSObject, ObservableObject {
    @Published private(set) var state: VoiceDictationState = .idle
    @Published private(set) var statusMessage: String?
    /// The draft the composer should display while a session is live; nil
    /// between sessions.
    @Published private(set) var liveDraft: String?

    private var transcript: DictationTranscriptState?
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var isAwaitingFinalResult = false
    private var finalResultTimeout: DispatchWorkItem?
    /// Bumped on every teardown so async permission callbacks captured by an
    /// earlier session can detect that they no longer own the controller.
    private var activeSession = 0

    private static let microphoneDeniedMessage = "Microphone access is needed for dictation. Allow it for PiNative in System Settings → Privacy & Security → Microphone."
    private static let speechPermissionDeniedMessage = "Speech recognition permission is needed for dictation. Allow it for PiNative in System Settings → Privacy & Security → Speech Recognition."

    var isActive: Bool { state != .idle }

    /// Starts dictation, appending recognized text to `baseDraft`. Requests
    /// speech and microphone permissions on first use.
    func start(baseDraft: String) {
        guard state == .idle else { return }
        // A session may still be finalizing after stop() (state is already
        // .idle, but its recognition task and timeout are live). Tear it down
        // before starting a fresh one so the stale timeout can't fire against
        // the new session and the old task can't keep feeding it results.
        teardownSession()
        statusMessage = nil
        liveDraft = nil
        transcript = DictationTranscriptState(baseDraft: baseDraft)
        state = .starting
        let session = activeSession
        requestPermissions { [weak self] granted, failureMessage in
            // Ignore a permission result for a session that was torn down or
            // superseded while the (async) request was pending, so a canceled
            // start can't begin capture on top of a newer session.
            guard let self, self.activeSession == session else { return }
            if granted {
                self.beginCapture()
            } else {
                self.fail(with: failureMessage ?? "Dictation is unavailable.")
            }
        }
    }

    /// Ends dictation gracefully, letting the recognizer deliver its final
    /// transcript so the last spoken words still land in the draft.
    func stop() {
        guard state != .idle else { return }
        guard state == .recording, let request = recognitionRequest else {
            cancel()
            return
        }
        state = .idle
        isAwaitingFinalResult = true
        audioEngine?.stop()
        request.endAudio()
        // The recognizer normally finishes within a moment of endAudio; the
        // timeout guarantees teardown even if it never delivers a final result.
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isAwaitingFinalResult else { return }
                self.cancel()
            }
        }
        finalResultTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
    }

    /// Tears dictation down immediately. No further transcript updates are
    /// published, and any text already merged into the draft stays there. Also
    /// used to end a session that completed naturally — the final transcript is
    /// already merged, so there is nothing extra to do.
    func cancel() {
        teardownSession()
    }

    // MARK: - Permissions

    private func requestPermissions(completion: @escaping @MainActor (Bool, String?) -> Void) {
        // The handler must be @Sendable: a closure literal written inside this
        // @MainActor class would otherwise inherit MainActor isolation, and
        // TCC invokes the handler on its own background queue, which traps on
        // the dynamic isolation check.
        SFSpeechRecognizer.requestAuthorization { @Sendable [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard status == .authorized else {
                    completion(false, VoiceDictationController.speechPermissionDeniedMessage)
                    return
                }
                self.requestMicrophonePermission(completion: completion)
            }
        }
    }

    private func requestMicrophonePermission(completion: @escaping @MainActor (Bool, String?) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true, nil)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { @Sendable granted in
                Task { @MainActor in
                    completion(granted, granted ? nil : VoiceDictationController.microphoneDeniedMessage)
                }
            }
        default:
            completion(false, VoiceDictationController.microphoneDeniedMessage)
        }
    }

    // MARK: - Capture and recognition

    private func beginCapture() {
        // The session may have been canceled while permissions were pending.
        guard transcript != nil else { return }

        let locale = Locale.current
        let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        // supportsOnDeviceRecognition must be checked up front: capture forces
        // requiresOnDeviceRecognition, so a recognizer that is merely
        // isAvailable (cloud-only for this locale) would otherwise fail late
        // with an opaque recognition error instead of this clear message.
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            fail(with: "On-device dictation isn't available for this language.")
            return
        }
        recognizer.delegate = self
        self.recognizer = recognizer

        let audioEngine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true

        // The engine tap is invoked on AVAudioEngine's input queue, so its
        // setup and start must happen off the main actor; a tap closure
        // written directly in this @MainActor method would inherit MainActor
        // isolation and trap on the audio queue.
        if let startFailure = Self.startAudioEngine(audioEngine, appendingTo: request) {
            fail(with: startFailure)
            return
        }

        recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            // Extract Sendable values on the recognizer's callback thread; the
            // recognition result object itself is not Sendable.
            let segment = result.map { (text: $0.bestTranscription.formattedString, isFinal: $0.isFinal) }
            let failureMessage = error.map { "Dictation stopped: \($0.localizedDescription)" }
            Task { @MainActor [weak self] in
                self?.handleRecognitionResult(segment: segment, failureMessage: failureMessage)
            }
        }

        self.audioEngine = audioEngine
        self.recognitionRequest = request
        state = .recording
    }

    private nonisolated static func startAudioEngine(_ audioEngine: AVAudioEngine, appendingTo request: SFSpeechAudioBufferRecognitionRequest) -> String? {
        let inputNode = audioEngine.inputNode
        let tapFormat = inputNode.outputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0 else {
            return "No microphone input is available."
        }
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            return "Dictation couldn't start: \(error.localizedDescription)"
        }
        return nil
    }

    private func handleRecognitionResult(segment: (text: String, isFinal: Bool)?, failureMessage: String?) {
        // A canceled session tears the transcript down first, so late results
        // are ignored instead of resurrecting a finished session.
        guard var session = transcript else { return }

        if let failureMessage {
            if isAwaitingFinalResult {
                // Expected once capture ended; the partial transcript already
                // merged into the draft is the best available result.
                cancel()
            } else {
                fail(with: failureMessage)
            }
            return
        }

        guard let segment else { return }
        session.apply(cumulativeTranscript: segment.text, isFinal: segment.isFinal)
        transcript = session
        publishDraft()

        if segment.isFinal {
            cancel()
        }
    }

    private func publishDraft() {
        guard let transcript else { return }
        liveDraft = transcript.composedDraft
    }

    private func fail(with message: String) {
        teardownSession()
        statusMessage = message
    }

    private func teardownSession() {
        if let audioEngine {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine = nil
        recognizer = nil
        transcript = nil
        isAwaitingFinalResult = false
        finalResultTimeout?.cancel()
        finalResultTimeout = nil
        activeSession += 1
        state = .idle
    }
}

extension VoiceDictationController: SFSpeechRecognizerDelegate {
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        guard !available else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isActive else { return }
            self.fail(with: "Dictation became unavailable.")
        }
    }
}
