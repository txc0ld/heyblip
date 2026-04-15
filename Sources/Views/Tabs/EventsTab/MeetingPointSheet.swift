import SwiftUI
import MapKit

private enum MeetingPointL10n {
    static let title = String(localized: "events.meeting_point.title", defaultValue: "Drop Meeting Point")
    static let cancel = String(localized: "common.cancel", defaultValue: "Cancel")
    static let adjustPin = String(localized: "events.meeting_point.adjust_pin", defaultValue: "Drag to adjust pin location")
    static let annotation = String(localized: "events.meeting_point.annotation", defaultValue: "Meeting Point")
    static let label = String(localized: "events.meeting_point.label", defaultValue: "Label")
    static let labelPlaceholder = String(localized: "events.meeting_point.label.placeholder", defaultValue: "e.g. Meet at the big tree")
    static let labelAccessibility = String(localized: "events.meeting_point.label.accessibility_label", defaultValue: "Meeting point label")
    static let expiresAfter = String(localized: "events.meeting_point.expires_after", defaultValue: "Expires after")
    static let shareWith = String(localized: "events.meeting_point.share_with", defaultValue: "Share with")
    static let friends = String(localized: "common.friends", defaultValue: "Friends")
    static let group = String(localized: "common.group", defaultValue: "Group")
    static let everyone = String(localized: "common.everyone", defaultValue: "Everyone")
    static let dropPin = String(localized: "events.meeting_point.drop_pin", defaultValue: "Drop Pin")

    static func expireAfter(_ option: String) -> String {
        String(format: String(localized: "events.meeting_point.expire_after_accessibility_label", defaultValue: "Expire after %@"), locale: Locale.current, option)
    }

    static func shareWith(_ label: String) -> String {
        String(format: String(localized: "events.meeting_point.share_with_accessibility_label", defaultValue: "Share with %@"), locale: Locale.current, label)
    }
}

// MARK: - MeetingPointSheet

/// Sheet for creating a meeting point: drop pin, add label, set expiry, share to group.
///
/// Presented as a glass bottom sheet. The user can type a label, pick an
/// expiry duration, and choose which group/friends to share with.
struct MeetingPointSheet: View {

    @Binding var isPresented: Bool

    let initialCoordinate: CLLocationCoordinate2D
    var onConfirm: ((MeetingPointData) -> Void)?

    @State private var label: String = ""
    @State private var selectedExpiry: ExpiryOption = .thirtyMinutes
    @State private var shareTarget: ShareTarget = .friends
    @State private var pinCoordinate: CLLocationCoordinate2D
    @State private var cameraPosition: MapCameraPosition

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isLabelFocused: Bool

    init(isPresented: Binding<Bool>, initialCoordinate: CLLocationCoordinate2D, onConfirm: ((MeetingPointData) -> Void)? = nil) {
        self._isPresented = isPresented
        self.initialCoordinate = initialCoordinate
        self.onConfirm = onConfirm
        self._pinCoordinate = State(initialValue: initialCoordinate)
        self._cameraPosition = State(initialValue: .region(
            MKCoordinateRegion(
                center: initialCoordinate,
                latitudinalMeters: 500,
                longitudinalMeters: 500
            )
        ))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GradientBackground()

                ScrollView {
                    VStack(spacing: BlipSpacing.lg) {
                        mapPinSection
                        labelSection
                        expirySection
                        shareSection
                        confirmButton
                    }
                    .padding(BlipSpacing.md)
                }
            }
            .navigationTitle(MeetingPointL10n.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(MeetingPointL10n.cancel) { isPresented = false }
                        .foregroundStyle(theme.colors.mutedText)
                }
            }
        }
    }

    // MARK: - Map Pin Section

    private var mapPinSection: some View {
        GlassCard(thickness: .regular) {
            VStack(spacing: BlipSpacing.sm) {
                Text(MeetingPointL10n.adjustPin)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)

                Map(position: $cameraPosition) {
                    Annotation(MeetingPointL10n.annotation, coordinate: pinCoordinate) {
                        VStack(spacing: 0) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(.blipAccentPurple)
                                .shadow(color: .blipAccentPurple.opacity(0.4), radius: 4)

                            if !label.isEmpty {
                                Text(label)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, BlipSpacing.sm)
                                    .padding(.vertical, BlipSpacing.xxs)
                                    .background(Capsule().fill(.blipAccentPurple))
                            }
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat))
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: BlipCornerRadius.md, style: .continuous))
            }
        }
    }

    // MARK: - Label Section

    private var labelSection: some View {
        GlassCard(thickness: .regular) {
            VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                Text(MeetingPointL10n.label)
                    .font(theme.typography.secondary)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.colors.text)

                TextField(MeetingPointL10n.labelPlaceholder, text: $label)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.text)
                    .padding(BlipSpacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: BlipCornerRadius.md, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: BlipCornerRadius.md, style: .continuous)
                            .stroke(
                                colorScheme == .dark ? .white.opacity(0.1) : .black.opacity(0.08),
                                lineWidth: BlipSizing.hairline
                            )
                    )
                    .focused($isLabelFocused)
                    .submitLabel(.done)
                    .accessibilityLabel(MeetingPointL10n.labelAccessibility)
                    .onChange(of: label) { _, newValue in
                        if newValue.count > 50 {
                            label = String(newValue.prefix(50))
                        }
                    }

                Text("\(label.count)/50")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.mutedText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    // MARK: - Expiry Section

    private var expirySection: some View {
        GlassCard(thickness: .regular) {
            VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                Text(MeetingPointL10n.expiresAfter)
                    .font(theme.typography.secondary)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.colors.text)

                HStack(spacing: BlipSpacing.sm) {
                    ForEach(ExpiryOption.allCases, id: \.self) { option in
                        expiryChip(option)
                    }
                }
            }
        }
    }

    private func expiryChip(_ option: ExpiryOption) -> some View {
        Button(action: { selectedExpiry = option }) {
            Text(option.displayString)
                .font(theme.typography.caption)
                .fontWeight(selectedExpiry == option ? .semibold : .regular)
                .foregroundStyle(selectedExpiry == option ? .white : theme.colors.text)
                .padding(.horizontal, BlipSpacing.md)
                .padding(.vertical, BlipSpacing.sm)
                .background(
                    Capsule()
                        .fill(selectedExpiry == option
                              ? AnyShapeStyle(LinearGradient.blipAccent)
                              : AnyShapeStyle(theme.colors.hover))
                )
        }
        .buttonStyle(.plain)
        .frame(minHeight: BlipSizing.minTapTarget)
        .accessibilityLabel(MeetingPointL10n.expireAfter(option.displayString))
        .accessibilityAddTraits(selectedExpiry == option ? .isSelected : [])
    }

    // MARK: - Share Section

    private var shareSection: some View {
        GlassCard(thickness: .regular) {
            VStack(alignment: .leading, spacing: BlipSpacing.sm) {
                Text(MeetingPointL10n.shareWith)
                    .font(theme.typography.secondary)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.colors.text)

                HStack(spacing: BlipSpacing.sm) {
                    shareOption(.friends, icon: "person.2.fill", label: MeetingPointL10n.friends)
                    shareOption(.group, icon: "person.3.fill", label: MeetingPointL10n.group)
                    shareOption(.everyone, icon: "globe", label: MeetingPointL10n.everyone)
                }
            }
        }
    }

    private func shareOption(_ target: ShareTarget, icon: String, label: String) -> some View {
        Button(action: { shareTarget = target }) {
            VStack(spacing: BlipSpacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(shareTarget == target ? .blipAccentPurple : theme.colors.mutedText)

                Text(label)
                    .font(theme.typography.caption)
                    .foregroundStyle(shareTarget == target ? theme.colors.text : theme.colors.mutedText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, BlipSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: BlipCornerRadius.md, style: .continuous)
                    .fill(shareTarget == target
                          ? .blipAccentPurple.opacity(0.12)
                          : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BlipCornerRadius.md, style: .continuous)
                    .stroke(shareTarget == target ? .blipAccentPurple.opacity(0.4) : .clear,
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .frame(minHeight: BlipSizing.minTapTarget)
        .accessibilityLabel(MeetingPointL10n.shareWith(label))
        .accessibilityAddTraits(shareTarget == target ? .isSelected : [])
    }

    // MARK: - Confirm Button

    private var confirmButton: some View {
        GlassButton(MeetingPointL10n.dropPin, icon: "mappin.and.ellipse") {
            let data = MeetingPointData(
                coordinate: pinCoordinate,
                label: label.isEmpty ? MeetingPointL10n.annotation : label,
                expiry: selectedExpiry,
                shareTarget: shareTarget
            )
            onConfirm?(data)
            isPresented = false
        }
        .fullWidth()
        .disabled(label.count > 50)
        .padding(.top, BlipSpacing.sm)
    }
}

// MARK: - Supporting Types

enum ExpiryOption: CaseIterable {
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case twoHours

    var displayString: String {
        switch self {
        case .fifteenMinutes: return "15 min"
        case .thirtyMinutes: return "30 min"
        case .oneHour: return "1 hour"
        case .twoHours: return "2 hours"
        }
    }

    var timeInterval: TimeInterval {
        switch self {
        case .fifteenMinutes: return 900
        case .thirtyMinutes: return 1800
        case .oneHour: return 3600
        case .twoHours: return 7200
        }
    }
}

enum ShareTarget {
    case friends
    case group
    case everyone
}

struct MeetingPointData {
    let coordinate: CLLocationCoordinate2D
    let label: String
    let expiry: ExpiryOption
    let shareTarget: ShareTarget
}

// MARK: - Preview

#Preview("Meeting Point Sheet") {
    MeetingPointSheet(
        isPresented: .constant(true),
        initialCoordinate: CLLocationCoordinate2D(latitude: 51.0043, longitude: -2.5856)
    )
    .preferredColorScheme(.dark)
    .blipTheme()
}
