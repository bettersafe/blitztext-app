import Foundation

// MARK: - Output Destination

/// Wohin das Ergebnis eines Workflows geht. Alle bisherigen Workflows setzen
/// den Text am Cursor ein, das Diktat schreibt in die Tagesdatei im Vault.
enum WorkflowOutputDestination {
    case cursor
    case vaultInbox
}

extension WorkflowType {
    var outputDestination: WorkflowOutputDestination {
        switch self {
        case .vaultDictation: return .vaultInbox
        case .transcription, .localTranscription, .textImprover, .dampfAblassen, .emojiText:
            return .cursor
        }
    }
}

// MARK: - Workflow State

enum WorkflowPhase: Equatable {
    case idle
    case running(String)
    case done(String)
    case error(String)

    var isActive: Bool {
        switch self {
        case .idle: return false
        default: return true
        }
    }
}

enum WorkflowLaunchSource: Equatable {
    case manual
    case hotkeyBackground

    var presentsWorkflowPage: Bool {
        switch self {
        case .manual:
            return true
        case .hotkeyBackground:
            return false
        }
    }
}

typealias WorkflowOutputHandler = @MainActor (String) -> Void
typealias WorkflowPhaseChangeHandler = @MainActor (WorkflowPhase) -> Void

// MARK: - Workflow Protocol

@MainActor
protocol Workflow: AnyObject, Observable {
    var type: WorkflowType { get }
    var phase: WorkflowPhase { get set }
    var isRecording: Bool { get }
    var onOutput: WorkflowOutputHandler? { get set }
    var onPhaseChange: WorkflowPhaseChangeHandler? { get set }

    func start()
    func stop()
    func reset()
}

// MARK: - App Settings

/// Backend that handles the remote (online) requests: either OpenAI directly
/// or an OpenAI-compatible proxy such as a LiteLLM gateway.
enum APIProvider: String, Codable, CaseIterable, Identifiable {
    case openAI
    case liteLLM

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .liteLLM: return "LiteLLM Gateway"
        }
    }
}

struct AppSettings: Codable {
    var hotkeyMode: HotkeyMode = .hold
    var hotkeyBindings: HotkeyBindings = HotkeyBindings()
    var hasSeenOnboarding: Bool = false
    var secureLocalModeEnabled: Bool = false
    /// Die Transkription bleibt auf dem Geraet, auch wenn die Nachbearbeitung
    /// ueber einen Anbieter laeuft.
    ///
    /// Unterschied zu `secureLocalModeEnabled`: der schaltet die Workflows mit
    /// KI-Nachbearbeitung ganz ab ("nichts verlaesst das Geraet"). Dieser
    /// Schalter nimmt ihnen nur den Tonversand -- Whisper laeuft lokal, und
    /// hinaus geht ausschliesslich der fertige Text. Fuer Betreiber mit einem
    /// maskierenden Gateway ist das der entscheidende Zustand: ein Filter kann
    /// Namen im Text unkenntlich machen, in einer Tonaufnahme nicht.
    var localTranscriptionAlways: Bool = false
    var selectedLocalTranscriptionModelName: String = LocalTranscriptionService.recommendedFastModelName
    var hasAutoSelectedFastLocalModel: Bool = false

    // Remote provider selection. `openAI` keeps the original direct-to-OpenAI path.
    var apiProvider: APIProvider = .openAI
    var liteLLMBaseURL: String = ""
    var liteLLMFastModel: String = "gpt-4o-mini"
    var liteLLMStrongModel: String = "gpt-4o"
    var liteLLMTranscriptionModel: String = "whisper-1"

    // Automatische Update-Pruefung, hoechstens einmal pro Kalendertag.
    var automaticUpdateChecksEnabled: Bool = true
    var lastUpdateCheck: Date?

    init(
        hotkeyMode: HotkeyMode = .hold,
        hotkeyBindings: HotkeyBindings = HotkeyBindings(),
        hasSeenOnboarding: Bool = false,
        secureLocalModeEnabled: Bool = false,
        localTranscriptionAlways: Bool = false,
        selectedLocalTranscriptionModelName: String = LocalTranscriptionService.recommendedFastModelName,
        hasAutoSelectedFastLocalModel: Bool = false,
        apiProvider: APIProvider = .openAI,
        liteLLMBaseURL: String = "",
        liteLLMFastModel: String = "gpt-4o-mini",
        liteLLMStrongModel: String = "gpt-4o",
        liteLLMTranscriptionModel: String = "whisper-1",
        automaticUpdateChecksEnabled: Bool = true,
        lastUpdateCheck: Date? = nil
    ) {
        self.hotkeyMode = hotkeyMode
        self.hotkeyBindings = hotkeyBindings
        self.hasSeenOnboarding = hasSeenOnboarding
        self.secureLocalModeEnabled = secureLocalModeEnabled
        self.localTranscriptionAlways = localTranscriptionAlways
        self.selectedLocalTranscriptionModelName = selectedLocalTranscriptionModelName
        self.hasAutoSelectedFastLocalModel = hasAutoSelectedFastLocalModel
        self.apiProvider = apiProvider
        self.liteLLMBaseURL = liteLLMBaseURL
        self.liteLLMFastModel = liteLLMFastModel
        self.liteLLMStrongModel = liteLLMStrongModel
        self.liteLLMTranscriptionModel = liteLLMTranscriptionModel
        self.automaticUpdateChecksEnabled = automaticUpdateChecksEnabled
        self.lastUpdateCheck = lastUpdateCheck
    }

    enum CodingKeys: String, CodingKey {
        case hotkeyMode
        case hotkeyBindings
        case hasSeenOnboarding
        case secureLocalModeEnabled
        case localTranscriptionAlways
        case selectedLocalTranscriptionModelName
        case hasAutoSelectedFastLocalModel
        case apiProvider
        case liteLLMBaseURL
        case liteLLMFastModel
        case liteLLMStrongModel
        case liteLLMTranscriptionModel
        case automaticUpdateChecksEnabled
        case lastUpdateCheck
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotkeyMode = try container.decodeIfPresent(HotkeyMode.self, forKey: .hotkeyMode) ?? .hold
        // Ein Formfehler nur bei hotkeyBindings darf nicht die gesamte
        // AppSettings-Dekodierung scheitern lassen: loadContainer() faengt
        // Fehler mit try? ab, das wuerde sonst alle Einstellungsgruppen auf
        // Standard zuruecksetzen. Deshalb hier lokal abfangen.
        hotkeyBindings = (try? container.decodeIfPresent(
            HotkeyBindings.self,
            forKey: .hotkeyBindings
        )) ?? HotkeyBindings()
        hasSeenOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasSeenOnboarding) ?? false
        secureLocalModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .secureLocalModeEnabled) ?? false
        localTranscriptionAlways = try container.decodeIfPresent(
            Bool.self,
            forKey: .localTranscriptionAlways
        ) ?? false
        selectedLocalTranscriptionModelName = try container.decodeIfPresent(
            String.self,
            forKey: .selectedLocalTranscriptionModelName
        ) ?? LocalTranscriptionService.recommendedFastModelName
        hasAutoSelectedFastLocalModel = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasAutoSelectedFastLocalModel
        ) ?? false
        apiProvider = try container.decodeIfPresent(APIProvider.self, forKey: .apiProvider) ?? .openAI
        liteLLMBaseURL = try container.decodeIfPresent(String.self, forKey: .liteLLMBaseURL) ?? ""
        liteLLMFastModel = try container.decodeIfPresent(String.self, forKey: .liteLLMFastModel) ?? "gpt-4o-mini"
        liteLLMStrongModel = try container.decodeIfPresent(String.self, forKey: .liteLLMStrongModel) ?? "gpt-4o"
        liteLLMTranscriptionModel = try container.decodeIfPresent(
            String.self,
            forKey: .liteLLMTranscriptionModel
        ) ?? "whisper-1"
        automaticUpdateChecksEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .automaticUpdateChecksEnabled
        ) ?? true
        lastUpdateCheck = try container.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
    }
}

enum TranscriptionBackend: String, Codable {
    case remote
    case local
}

// MARK: - Workflow Settings

struct TranscriptionSettings: Codable {
    var language: String = "de"
}

struct DampfAblassenSettings: Codable {
    var systemPrompt: String = "Du erhältst ein emotional gesprochenes Transkript. Erkenne zuerst das eigentliche Ziel, Anliegen und den wahren Frust der Person. Formuliere daraus eine klare, respektvolle und wirksame Nachricht, mit der die Person ihr Ziel eher erreicht. Bewahre relevante Fakten, konkrete Probleme, Grenzen, Erwartungen und die nötige Dringlichkeit. Entferne Beleidigungen, Drohungen, Sarkasmus, Unterstellungen und unnötige Eskalation. Wenn mehrere Vorwürfe genannt werden, verdichte sie auf die entscheidenden Kernpunkte. Der Ton soll ruhig, menschlich, bestimmt und lösungsorientiert sein. Gib NUR die fertige Nachricht zurück."
    var customName: String = ""
}

struct EmojiTextSettings: Codable {
    var emojiDensity: EmojiDensity = .mittel
    var customName: String = ""

    enum EmojiDensity: String, Codable, CaseIterable, Identifiable {
        case wenig
        case mittel
        case viel

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .wenig: return "Wenig"
            case .mittel: return "Mittel"
            case .viel: return "Viel"
            }
        }
    }
}

struct TextImprovementSettings: Codable {
    var systemPrompt: String = ""
    var customTerms: [String] = []
    var context: String = ""
    var tone: TextTone = .neutral
    var customName: String = ""

    enum TextTone: String, Codable, CaseIterable, Identifiable {
        case formal
        case neutral
        case casual

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .formal: return "Formell"
            case .neutral: return "Neutral"
            case .casual: return "Locker"
            }
        }
    }
}
