import Foundation

/// API endpoint paths configuration
public struct APIPaths {
    /// Anonymous session creation endpoint
    public var anonymousSession: String
    
    /// Conversations list/detail endpoint
    public var conversations: String
    
    /// Agent runs endpoint
    public var runs: String
    
    /// Run events SSE endpoint (use {runId} as placeholder)
    public var runEvents: String
    
    /// Cancel run endpoint (use {runId} as placeholder)
    public var cancelRun: String?
    
    /// Simulate customer endpoint (for demo flows)
    public var simulateCustomer: String
    
    /// TTS voices endpoint
    public var ttsVoices: String
    
    /// TTS set voice endpoint
    public var ttsSetVoice: String
    
    /// Available models endpoint
    public var models: String
    
    /// Tasks endpoint
    public var tasks: String

    /// Systems discovery endpoint
    public var systems: String

    /// Agents discovery endpoint
    public var agents: String

    public init(
        anonymousSession: String = "/api/accounts/anonymous-session/",
        conversations: String = "/api/agent-runtime/conversations/",
        runs: String = "/api/agent-runtime/runs/",
        runEvents: String = "/api/agent-runtime/runs/{runId}/events/",
        cancelRun: String? = nil,
        simulateCustomer: String = "/api/agent-runtime/simulate-customer/",
        ttsVoices: String = "/api/tts/voices/",
        ttsSetVoice: String = "/api/tts/set-voice/",
        models: String = "/api/agent-runtime/models/",
        tasks: String = "/api/agent/tasks/",
        systems: String = "/api/agent-runtime/systems/",
        agents: String = "/api/agent-runtime/agents/"
    ) {
        self.anonymousSession = anonymousSession
        self.conversations = conversations
        self.runs = runs
        self.runEvents = runEvents
        self.cancelRun = cancelRun
        self.simulateCustomer = simulateCustomer
        self.ttsVoices = ttsVoices
        self.ttsSetVoice = ttsSetVoice
        self.models = models
        self.tasks = tasks
        self.systems = systems
        self.agents = agents
    }
    
    /// Get the run events URL with the run ID substituted
    public func runEventsUrl(for runId: String) -> String {
        return runEvents.replacingOccurrences(of: "{runId}", with: runId)
    }
    
    /// Get the cancel run URL with the run ID substituted
    public func cancelRunUrl(for runId: String) -> String {
        if let cancelRun = cancelRun {
            return cancelRun.replacingOccurrences(of: "{runId}", with: runId)
        }
        return "\(runs)\(runId)/cancel/"
    }
}

