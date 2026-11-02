import AVFoundation
import Speech
import UIKit

/// Dictation for the panel's keyboard.
///
/// The system keyboard's mic belongs to the system keyboard: a field whose `inputView` is
/// the app's own board has no way to reach it. So the board listens for itself, with the
/// same recogniser the system uses, and on the device where the device can — a note
/// spoken over a highlight never has to leave the phone.
///
/// What is heard is shown on the board as it comes in and only typed into the field once
/// it is settled, in one piece. Streaming the guesses into the field would mean taking
/// back words the recogniser changes its mind about, and a web field cannot be trusted
/// to take back exactly what it was given.
@MainActor
final class AmberDictation: ObservableObject {
    enum State: Equatable {
        case idle
        /// Waiting on permission, or on the microphone.
        case starting
        case listening
        /// Told to stop; waiting on the recogniser's last word.
        case finishing
        /// Could not start. The board says why, then goes back to its keys.
        case refused(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = ""

    var isActive: Bool {
        switch state {
        case .starting, .listening, .finishing: return true
        case .idle, .refused: return false
        }
    }

    /// Whether to offer the mic at all. A language the recogniser does not know has no
    /// recogniser, and the key would only ever say so.
    static let isOffered = SFSpeechRecognizer() != nil

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onCommit: (String) -> Void = { _ in }
    private var settleDeadline: Task<Void, Never>?
    /// Whether this attempt is being heard on the device. If the device's own model
    /// cannot be loaded, the attempt is made once more with Apple's servers.
    private var onDevice = false
    private var startedAt = Date.distantPast
    private var refusalTimer: Task<Void, Never>?

    // MARK: - Listening

    func start(onCommit: @escaping (String) -> Void) {
        guard !isActive else { return }
        self.onCommit = onCommit
        transcript = ""
        refusalTimer?.cancel()
        state = .starting
        Task {
            guard await Self.authorize() else {
                refuse("Allow the microphone and speech recognition for Evening Reader in Settings.")
                return
            }
            begin(preferOnDevice: true)
        }
    }

    /// Stops listening. What was heard is typed in once the recogniser has finished
    /// with it, or after a moment if it is slow to.
    func stop() {
        guard state == .listening || state == .starting else { return }
        guard state == .listening else { teardown(); state = .idle; return }
        state = .finishing
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        settleDeadline = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.commit()
        }
    }

    /// Types in what has been heard so far, at once. For a key pressed mid-sentence: the
    /// words belong before the key, not after it.
    func commitNow() {
        guard isActive else { return }
        commit()
    }

    /// Lets go of the microphone and drops what was heard. For a board leaving the screen,
    /// when there is no longer a field to type it into.
    func cancel() {
        guard isActive else { return }
        teardown()
        transcript = ""
        state = .idle
    }

    private func begin(preferOnDevice: Bool) {
        // Stopped while the permission prompt was up.
        guard state == .starting else { return }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            refuse("Dictation isn’t available right now.")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        onDevice = preferOnDevice && recognizer.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = onDevice

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw DictationError.noMicrophone }
            input.installTap(onBus: 0, bufferSize: 1024, format: format,
                             block: Self.feed(request))
            engine.prepare()
            try engine.start()
        } catch {
            teardown()
            refuse("The microphone couldn’t be started.")
            return
        }

        self.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.handler(for: self))
        startedAt = Date()
        state = .listening
    }

    private func receive(text: String?, isFinal: Bool, failed: Bool) {
        guard isActive else { return }
        // A failure straight away, before a word is heard, is the recogniser not starting
        // — the device's own model would not load. One more try, heard by Apple's servers
        // instead. A failure later on is it giving up on silence, which ends quietly.
        let couldNotStart = failed && text == nil && transcript.isEmpty
            && state == .listening && Date().timeIntervalSince(startedAt) < 2
        if couldNotStart {
            teardown()
            if onDevice {
                state = .starting
                begin(preferOnDevice: false)
            } else {
                refuse("Dictation isn’t available right now.")
            }
            return
        }
        if let text { transcript = text }
        // The recogniser has finished — because it was told to, or because it heard
        // nothing more for long enough, or because it gave up. Either way, what it has
        // is what there is.
        if isFinal || failed { commit() }
    }

    private func commit() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        teardown()
        transcript = ""
        state = .idle
        if !text.isEmpty { onCommit(text) }
    }

    private func refuse(_ reason: String) {
        teardown()
        state = .refused(reason)
        refusalTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, let self, case .refused = self.state else { return }
            self.state = .idle
        }
    }

    private func teardown() {
        settleDeadline?.cancel()
        settleDeadline = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Off the main thread

    /// The tap runs on the audio thread, so it is built outside the main actor and
    /// touches nothing but the request.
    private nonisolated static func feed(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    private nonisolated static func handler(for owner: AmberDictation) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in owner?.receive(text: text, isFinal: isFinal, failed: failed) }
        }
    }

    private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    private enum DictationError: Error { case noMicrophone }

    // MARK: - Typing it in

    /// Types dictated words in at the caret, set off by a space from a word already
    /// standing right before it — what the system's dictation does.
    static func insert(_ text: String, into input: UIKeyInput?) {
        guard let input, !text.isEmpty else { return }
        var words = text
        if let field = input as? UITextInput,
           let caret = field.selectedTextRange?.start,
           let before = field.position(from: caret, offset: -1),
           let range = field.textRange(from: before, to: caret),
           let previous = field.text(in: range)?.last,
           !previous.isWhitespace {
            words = " " + words
        }
        input.insertText(words)
    }
}
