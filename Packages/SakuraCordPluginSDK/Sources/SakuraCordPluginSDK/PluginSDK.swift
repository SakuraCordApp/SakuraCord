import Foundation

public struct PluginManifest: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var publisher: String
    public var version: String
    public var minimumHostVersion: String
    public var entryComponent: String
    public var capabilities: Set<PluginCapability>
    public var networkOrigins: Set<String>

    public init(id: String, name: String, publisher: String, version: String, minimumHostVersion: String, entryComponent: String, capabilities: Set<PluginCapability>, networkOrigins: Set<String> = []) {
        self.id = id
        self.name = name
        self.publisher = publisher
        self.version = version
        self.minimumHostVersion = minimumHostVersion
        self.entryComponent = entryComponent
        self.capabilities = capabilities
        self.networkOrigins = networkOrigins
    }
}

public enum PluginCapability: String, Codable, Hashable, CaseIterable, Sendable {
    case readMessages, sendMessages, editMessages, deleteMessages, uploadFiles
    case readMembers, subscribeEvents, addCommands, addPanels, decorateMessages
    case privateStorage, clipboardRead, notifications, selectedFiles, network

    public var isSensitive: Bool {
        switch self {
        case .sendMessages, .editMessages, .deleteMessages, .uploadFiles, .clipboardRead, .selectedFiles, .network: true
        default: false
        }
    }
}

public enum PermissionScope: Codable, Hashable, Sendable {
    case once
    case account(String)
    case guild(String)
    case channel(String)
    case origin(String)
}

public struct PluginPermissionRequest: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var pluginID: String
    public var capability: PluginCapability
    public var reason: String
    public var proposedScope: PermissionScope

    public init(id: UUID = UUID(), pluginID: String, capability: PluginCapability, reason: String, proposedScope: PermissionScope = .once) {
        self.id = id
        self.pluginID = pluginID
        self.capability = capability
        self.reason = reason
        self.proposedScope = proposedScope
    }
}
