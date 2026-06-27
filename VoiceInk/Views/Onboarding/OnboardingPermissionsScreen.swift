import SwiftUI

struct OnboardingPermissionsScreen: View {
    let contentMaxWidth: CGFloat
    let isComplete: Bool
    let activePermission: OnboardingPermissionKind
    let hasRequestedScreenRecording: Bool
    let hasRequestedAccessibility: Bool
    let stepNumber: (OnboardingPermissionKind) -> Int
    let status: (OnboardingPermissionKind) -> OnboardingPermissionStatus
    let isLocked: (OnboardingPermissionKind) -> Bool
    let actionTitle: (OnboardingPermissionKind) -> String
    let onSelect: (OnboardingPermissionKind) -> Void
    let onAction: (OnboardingPermissionKind) -> Void
    let onQuit: () -> Void
    let onRecheck: () -> Void
    let onContinue: () -> Void

    var body: some View {
        OnboardingStepScreen(
            stage: .permissions,
            contentMaxWidth: contentMaxWidth
        ) {
            permissionList
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Recheck",
                primaryTitle: "Continue",
                isPrimaryEnabled: isComplete,
                onLeading: onRecheck,
                onPrimary: onContinue
            )
        }
    }

    // A permission can read as enabled in System Settings yet still be inactive for the
    // running app (most often Accessibility on an ad-hoc-signed build, where the grant is
    // pinned to a code signature that changed on the last rebuild). When that happens the
    // "Recheck" button can never flip to granted, so surface a recovery hint.
    private func showsRestartHint(for permission: OnboardingPermissionKind) -> Bool {
        switch permission {
        case .screenRecording:
            return hasRequestedScreenRecording && !status(.screenRecording).isGranted
        case .accessibility:
            return hasRequestedAccessibility && !status(.accessibility).isGranted
        case .microphone:
            return false
        }
    }

    private func restartHintMessage(for permission: OnboardingPermissionKind) -> LocalizedStringKey {
        switch permission {
        case .accessibility:
            return "Enabled it but still blocked? Toggle Accessibility off and on for Quill, then quit and reopen."
        default:
            return "Restart Quill after enabling Screen Recording."
        }
    }

    private var permissionList: some View {
        VStack(spacing: 10) {
            ForEach(OnboardingPermissionKind.allCases) { permission in
                PermissionStepRow(
                    stepNumber: stepNumber(permission),
                    descriptor: permission.descriptor,
                    status: status(permission),
                    isActive: !isComplete && activePermission == permission,
                    isLocked: isLocked(permission),
                    showsRestartHint: showsRestartHint(for: permission),
                    restartHintMessage: restartHintMessage(for: permission),
                    actionTitle: actionTitle(permission),
                    onSelect: {
                        guard !isLocked(permission) else { return }
                        onSelect(permission)
                    },
                    onAction: {
                        onAction(permission)
                    },
                    onQuit: onQuit
                )
            }
        }
    }
}
