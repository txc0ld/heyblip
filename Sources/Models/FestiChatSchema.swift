import Foundation
import SwiftData

/// Central schema and ModelContainer configuration for all Blip SwiftData models.
enum BlipSchema {

    /// All SwiftData model types registered in the app.
    static let models: [any PersistentModel.Type] = [
        User.self,
        Friend.self,
        Message.self,
        Attachment.self,
        Channel.self,
        GroupMembership.self,
        Event.self,
        Stage.self,
        SetTime.self,
        MeetingPoint.self,
        MessageQueue.self,
        SOSAlert.self,
        MedicalResponder.self,
        FriendLocation.self,
        BreadcrumbPoint.self,
        CrowdPulse.self,
        UserPreferences.self,
        GroupSenderKey.self,
        NoiseSessionModel.self,
        JoinedEvent.self
    ]

    /// The SwiftData Schema containing all model types.
    static var schema: Schema {
        Schema(models)
    }

    /// Creates the default ModelConfiguration for production use.
    static var defaultConfiguration: ModelConfiguration {
        ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .automatic
        )
    }

    /// Creates an in-memory ModelConfiguration for previews and testing.
    static var previewConfiguration: ModelConfiguration {
        ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
    }

    /// Ensure the Application Support directory exists before SwiftData/CoreData
    /// tries to create the store file. On first launch the directory may not exist,
    /// causing ~100 "Failed to stat path" warnings in the console.
    static func ensureStoreDirectoryExists() {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }
        try? FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true
        )
    }

    /// Creates the production ModelContainer.
    @MainActor
    static func createContainer() throws -> ModelContainer {
        ensureStoreDirectoryExists()
        return try ModelContainer(
            for: schema,
            configurations: [defaultConfiguration]
        )
    }

    /// Creates an in-memory ModelContainer for previews and testing.
    @MainActor
    static func createPreviewContainer() throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            configurations: [previewConfiguration]
        )
    }
}
