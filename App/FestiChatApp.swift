import SwiftUI
import SwiftData

@main
struct FestiChatApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @Environment(\.colorScheme) private var colorScheme

    var sharedModelContainer: ModelContainer = {
        do {
            return try ModelContainer(
                for: FestiChatSchema.schema,
                configurations: [FestiChatSchema.defaultConfiguration]
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.theme, Theme.shared)
                .preferredColorScheme(nil)
        }
        .modelContainer(sharedModelContainer)
    }
}

// MARK: - RootView

/// Root navigation: Splash -> Onboarding (if first launch) -> MainTabView.
struct RootView: View {

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showSplash = true
    @State private var appPhase: AppPhase = .splash
    @Environment(\.theme) private var theme

    enum AppPhase: Equatable {
        case splash
        case onboarding
        case main
    }

    var body: some View {
        ZStack {
            switch appPhase {
            case .splash:
                SplashView {
                    withAnimation(SpringConstants.accessibleReveal) {
                        appPhase = hasCompletedOnboarding ? .main : .onboarding
                    }
                }
                .transition(.opacity)

            case .onboarding:
                OnboardingFlow {
                    hasCompletedOnboarding = true
                    withAnimation(SpringConstants.accessibleReveal) {
                        appPhase = .main
                    }
                }
                .transition(.opacity)

            case .main:
                MainTabView()
                    .transition(.opacity)
            }
        }
        .animation(SpringConstants.accessibleReveal, value: appPhase)
    }
}

