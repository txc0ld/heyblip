import SwiftUI
import SwiftData

@main
struct BlipApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @AppStorage("appTheme") private var appTheme: AppTheme = .system

    @Environment(\.scenePhase) private var scenePhase
    @State private var coordinator = AppCoordinator()

    var sharedModelContainer: ModelContainer = {
        BlipSchema.ensureStoreDirectoryExists()
        do {
            return try ModelContainer(
                for: BlipSchema.schema,
                configurations: [BlipSchema.defaultConfiguration]
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
                .preferredColorScheme(appTheme.colorScheme)
                .animation(.easeInOut(duration: 0.3), value: appTheme)
                .onAppear {
                    if !coordinator.isReady && !coordinator.needsOnboarding {
                        coordinator.configure(modelContainer: sharedModelContainer)
                    }
                }
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                coordinator.backgroundTaskService?.scheduleNextSync()
                if coordinator.bleService?.state == .running {
                    coordinator.backgroundTaskService?.postBackgroundActiveNotification()
                }
            case .active:
                coordinator.backgroundTaskService?.removeBackgroundActiveNotification()
            default:
                break
            }
        }
    }
}

// MARK: - RootView

/// Root navigation: Splash -> Onboarding (if first launch) -> MainTabView.
struct RootView: View {

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var appPhase: AppPhase = .splash
    @State private var showSetupError = false
    @State private var isRetrying = false
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
                    completeOnboarding()
                }
                .transition(.opacity)
                .overlay {
                    if showSetupError {
                        setupErrorOverlay
                    }
                }

            case .main:
                MainTabView(coordinator: coordinator)
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
        .onChange(of: coordinator.needsOnboarding) { _, needsOnboarding in
            guard needsOnboarding else { return }
            hasCompletedOnboarding = false
            withAnimation(SpringConstants.accessibleReveal) {
                appPhase = .onboarding
            }
        }
    }

    // MARK: - Onboarding Completion

    private func completeOnboarding() {
        hasCompletedOnboarding = true

        let ready = coordinator.reconfigureAfterOnboarding(
            modelContainer: modelContext.container
        )

        if ready {
            showSetupError = false
            withAnimation(SpringConstants.accessibleReveal) {
                appPhase = .main
            }
        } else {
            withAnimation(SpringConstants.accessibleReveal) {
                showSetupError = true
            }
        }
    }

    private func retrySetup() {
        isRetrying = true

        let ready = coordinator.reconfigureAfterOnboarding(
            modelContainer: modelContext.container
        )

        isRetrying = false

        if ready {
            withAnimation(SpringConstants.accessibleReveal) {
                showSetupError = false
                appPhase = .main
            }
        }
    }

    // MARK: - Error Overlay

    private var setupErrorOverlay: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            VStack(spacing: BlipSpacing.lg) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.blipAccentPurple)

                Text("Setup Failed")
                    .font(theme.typography.headline)
                    .foregroundStyle(theme.colors.text)

                Text(coordinator.initError ?? "Something went wrong setting up your account.")
                    .font(theme.typography.secondary)
                    .foregroundStyle(theme.colors.mutedText)
                    .multilineTextAlignment(.center)

                VStack(spacing: BlipSpacing.md) {
                    GlassButton("Try Again", icon: "arrow.clockwise", isLoading: isRetrying) {
                        retrySetup()
                    }
                    .fullWidth()

                    Button {
                        withAnimation(SpringConstants.accessibleReveal) {
                            hasCompletedOnboarding = false
                            showSetupError = false
                            coordinator.resetToOnboarding()
                        }
                    } label: {
                        Text("Restart Onboarding")
                            .font(theme.typography.secondary)
                            .foregroundStyle(theme.colors.mutedText)
                    }
                    .frame(minHeight: BlipSizing.minTapTarget)
                }
            }
            .padding(BlipSpacing.xl)
        }
        .transition(.opacity)
    }
}
