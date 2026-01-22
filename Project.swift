import Foundation
import ProjectDescription

let teamId = ProcessInfo.processInfo.environment["CODE_SIGN_TEAM_ID"] ?? ""
var baseSettings: SettingsDictionary = [
    "CODE_SIGN_STYLE": "Automatic",
    "CODE_SIGN_IDENTITY": "Apple Development",
    "PROVISIONING_PROFILE_SPECIFIER": ""
]
if !teamId.isEmpty {
    baseSettings["DEVELOPMENT_TEAM"] = .string(teamId)
}
let entitlements: Entitlements? = teamId.isEmpty ? nil : .file(path: "Entitlements/CodexSessions.entitlements")

let project = Project(
    name: "CodexSessions",
    organizationName: "CodexSessions",
    settings: .settings(base: baseSettings),
    targets: [
        .target(
            name: "CodexSessions",
            destinations: .macOS,
            product: .app,
            bundleId: "com.example.CodexSessions",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .file(path: "Resources/Info.plist"),
            sources: ["Sources/Shared/**", "Sources/macOS/**"],
            resources: [.glob(pattern: "Resources/**", excluding: ["Resources/iOS/**", "Resources/Info.plist"])],
            entitlements: entitlements,
            settings: .settings(base: baseSettings)
        ),
        .target(
            name: "CodexSessionsiOS",
            destinations: .iOS,
            product: .app,
            bundleId: "com.example.CodexSessions.iOS",
            deploymentTargets: .iOS("17.0"),
            infoPlist: .file(path: "Resources/iOS/Info.plist"),
            sources: ["Sources/Shared/**", "Sources/iOS/**"],
            resources: [.glob(pattern: "Resources/iOS/**", excluding: ["Resources/iOS/Info.plist"])],
            entitlements: entitlements,
            settings: .settings(base: baseSettings)
        )
    ]
)
