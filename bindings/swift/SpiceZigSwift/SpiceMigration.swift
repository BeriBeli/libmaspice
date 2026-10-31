import Foundation

public struct SpiceMigrationDestination: Sendable, Equatable {
    public let host: String
    public let port: UInt16?
    public let securePort: UInt16?
    public let certificateSubject: String?

    public init(
        host: String,
        port: UInt16?,
        securePort: UInt16?,
        certificateSubject: String?
    ) {
        self.host = host
        self.port = port
        self.securePort = securePort
        self.certificateSubject = certificateSubject
    }


}

public enum SpiceMigrationMode: Sendable, Equatable {
    case semiSeamless
    case seamless(sourceVersion: UInt32)
    case switchHost
}

public struct SpiceMigrationOffer: Sendable, Equatable {
    public let id: UInt64
    public let destination: SpiceMigrationDestination
    public let mode: SpiceMigrationMode

    public init(
        id: UInt64,
        destination: SpiceMigrationDestination,
        mode: SpiceMigrationMode
    ) {
        self.id = id
        self.destination = destination
        self.mode = mode
    }
}

public enum SpiceMigrationEvent: Sendable, Equatable {
    case preparing(SpiceMigrationOffer)
    case ready(SpiceMigrationOffer, seamless: Bool)
    case cancelled(SpiceMigrationOffer)
    case committing(SpiceMigrationOffer)
    case switching(SpiceMigrationOffer)
    case completed(SpiceMigrationOffer)
    case failed(SpiceMigrationOffer?, reason: String)
}

