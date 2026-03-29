import SwiftUI
import SwiftData

@main
struct FestiChatApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @Environment(\.colorScheme) private var colorScheme

    @State private var coordinator = AppCoordinator()

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
            RootView(coordinator: coordinator)
                .environment(coordinator)
                .environment(\.theme, Theme.shared)
                .preferredColorScheme(nil)
                .onAppear {
                    if !coordinator.isReady && !coordinator.needsOnboarding {
                        coordinator.configure(modelContainer: sharedModelContainer)
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}

// MARK: - RootView

/// Root navigation: Splash -> Onboarding (if first launch) -> MainTabView.
struct RootView: View {

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var appPhase: AppPhase = .splash
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext

    var coordinator: AppCoordinator

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
                        if coordinator.needsOnboarding || !hasCompletedOnboarding {
                            appPhase = .onboarding
                        } else {
                            appPhase = .main
                        }
                    }
                }
                .transition(.opacity)

            case .onboarding:
                OnboardingFlow {
                    hasCompletedOnboarding = true
                    coordinator.reconfigureAfterOnboarding(
                        modelContainer: modelContext.container
                    )
                    withAnimation(SpringConstants.accessibleReveal) {
                        appPhase = .main
                    }
                }
                .transition(.opacity)

            case .main:
                MainTabView()
                    .transition(.opacity)
                    .onAppear {
                        if coordinator.isReady {
                            coordinator.start()
                        }
                    }
                    .onDisappear {
                        coordinator.stop()
                    }
            }
        }
        .animation(SpringConstants.accessibleReveal, value: appPhase)
    }
}

