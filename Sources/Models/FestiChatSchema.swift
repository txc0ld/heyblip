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
        Festival.self,
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
        NoiseSessionModel.self
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

    /// Creates the production ModelContainer.
    @MainActor
    static func createContainer() throws -> ModelContainer {
        try ModelContainer(
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
