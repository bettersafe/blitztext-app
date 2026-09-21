import Foundation
import AppKit
import Observation

@Observable
@MainActor
final class DampfAblassenWorkflow: Workflow {
    let type = WorkflowType.dampfAblassen
    var phase: WorkflowPhase = .idle {
        didSet { onPhaseChange?(phase) }
    }
    var onOutput: WorkflowOutputHandler?
    var onPhaseChange: WorkflowPhaseChangeHandler?

    private let recorder = AudioRecorder()
    private let settings: DampfAblassenSettings
    private let customTerms: [String]
    private let language: String
    private let apiConfiguration: APIConfiguration
    private let backend: TranscriptionBackend
    private let localModelName: String
    private var processingTask: Task<Void, Never>?

    init(
        settings: DampfAblassenSettings,
        customTerms: [String] = [],
        language: String = "de",
        apiConfiguration: APIConfiguration,
        backend: TranscriptionBackend = .remote,
        localModelName: String = LocalTranscriptionService.recommendedFastModelName
    ) {
        self.settings = settings
        self.customTerms = customTerms
        self.language = language
        self.apiConfiguration = apiConfiguration
        self.backend = backend
        self.localModelName = localModelName
    }

    // MARK: - Recording State

    var isRecording: Bool { recorder.isRecording }
    var audioLevel: Float { recorder.audioLevel }

    // MARK: - Workflow Protocol

    func start() {
        phase = .running("Aufnahme läuft ...")
        recorder.startRecording()

        if let error = recorder.errorMessage {
            phase = .error(error)
        }
    }

    func stop() {
        if recorder.isRecording {
            recorder.stopRecording()
            guard !TranscriptionQualityService.shouldRejectRecording(duration: recorder.lastRecordingDuration) else {
                recorder.discardRecording()
                phase = .error("Keine Aufnahme erkannt.")
                return
            }
            processRecording()
        } else {
            processingTask?.cancel()
            phase = .idle
        }
    }

    func reset() {
        processingTask?.cancel()
        if recorder.isRecording {
            recorder.stopRecording()
        }
        recorder.discardRecording()
        phase = .idle
    }

    // MARK: - Two-Phase Processing: Whisper -> GPT Rage Mode

    private func processRecording() {
        guard let url = recorder.recordingURL else {
            phase = .error("Keine Aufnahme vorhanden.")
            return
        }

        phase = .running("Wird transkribiert ...")
        let recordingDuration = recorder.lastRecordingDuration
        let vocabularyHints = recordingDuration >= 0.9 ? customTerms : []

        processingTask = Task {
            defer {
                try? FileManager.default.removeItem(at: url)
            }

            do {
                // Phase 1: Transkription -- auf dem Geraet oder beim Anbieter.
                // Ein maskierendes Gateway kann Namen im TEXT unkenntlich
                // machen, in einer Tonaufnahme nicht. Wer den Ton nicht
                // herausgeben will, laesst Whisper lokal laufen und schickt
                // nur das Ergebnis weiter.
                let rawText: String
                switch backend {
                case .local:
                    rawText = try await LocalTranscriptionService.shared.transcribe(
                        audioURL: url,
                        language: language,
                        modelName: localModelName
                    )
                case .remote:
                    rawText = try await TranscriptionService.transcribe(
                        audioURL: url,
                        customTerms: vocabularyHints,
                        language: language,
                        config: apiConfiguration
                    )
                }
                let cleanedRawText = TranscriptionQualityService.cleanedTranscript(rawText)
                guard !TranscriptionQualityService.isLikelyArtifact(cleanedRawText, recordingDuration: recordingDuration) else {
                    phase = .error("Keine Aufnahme erkannt.")
                    return
                }

                if Task.isCancelled { return }

                // Phase 2: GPT dampf ablassen
                phase = .running("Wird umformuliert ...")

                let answer = try await LLMService.dampfAblassen(
                    text: cleanedRawText,
                    systemPrompt: settings.systemPrompt,
                    config: apiConfiguration
                )
                let cleanedAnswer = TranscriptionQualityService.cleanedTranscript(answer)
                guard cleanedAnswer != "KEINE_AUFNAHME_ERKANNT" else {
                    phase = .error("Keine Aufnahme erkannt.")
                    return
                }
                phase = .done(cleanedAnswer)
                onOutput?(cleanedAnswer)
                recordDictationHistory(workflow: type, audioURL: url, input: cleanedRawText, output: cleanedAnswer)
            } catch {
                phase = .error(error.localizedDescription)
            }
        }
    }
}
