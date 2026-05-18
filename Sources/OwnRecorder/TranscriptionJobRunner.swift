import Foundation

@MainActor
final class TranscriptionJobRunner {
    static let shared = TranscriptionJobRunner()

    private let manager = TranscriptionManager()
    private var processingSessions = Set<String>()
    private var sessionStages: [String: String] = [:]

    private init() {}

    func isProcessing(sessionId: String) -> Bool {
        processingSessions.contains(sessionId)
    }

    func stage(for sessionId: String) -> String? {
        sessionStages[sessionId]
    }

    func processingSnapshot() -> (ids: Set<String>, stages: [String: String]) {
        (processingSessions, sessionStages)
    }

    /// Returns false if the session is already being processed.
    func startReprocess(sessionId: String) -> Bool {
        guard !processingSessions.contains(sessionId) else { return false }
        guard let sessionDir = RecordsIndex.sessionDirectory(forSessionId: sessionId) else { return false }

        processingSessions.insert(sessionId)
        sessionStages[sessionId] = "transcribing"

        manager.onStageChanged = { [weak self] stage in
            Task { @MainActor in
                guard let self else { return }
                switch stage {
                case .transcribing:
                    self.sessionStages[sessionId] = "transcribing"
                case .summarizing:
                    self.sessionStages[sessionId] = "summarizing"
                }
            }
        }

        Task {
            do {
                _ = try await manager.reprocess(sessionDir: sessionDir)
                Logger.shared.info("TranscriptionJobRunner: reprocess complete for \(sessionId)")
            } catch {
                TranscriptionManager.persistError(error, sessionDir: sessionDir)
                Logger.shared.error("TranscriptionJobRunner: reprocess failed for \(sessionId) — \(error.localizedDescription)")
            }
            processingSessions.remove(sessionId)
            sessionStages.removeValue(forKey: sessionId)
            manager.onStageChanged = nil
        }
        return true
    }
}
