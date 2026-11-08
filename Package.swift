// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "SeeSoundDataChecks",
    platforms: [.macOS(.v13), .iOS("17.3")],
    products: [.library(name: "SeeSoundData", targets: ["SeeSoundData"])],
    dependencies: [.package(path: "Vendor/GRDB.swift")],
    targets: [
        .target(name: "SeeSoundData", dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
                path: ".", exclude: ["Checks", "References", "Resources", "Watch", "docs", "Vendor", "SeeSound.xcodeproj",
                                     "README.md", "验证记录.txt", "ShareExtension", "App/SeeSound.entitlements", "UITests", "App/VisualDesign.swift", "App/CampusViews.swift", "App/CampusWorkspaceViews.swift", "App/CampusCommunicationViews.swift", "App/CounterVisitViews.swift", "App/CampusEvaluationViews.swift", "App/CaseEfficiencyViews.swift", "App/RecoveryExperienceViews.swift", "App/ExampleExperienceViews.swift", "App/WorkspaceUpgradeViews.swift", "App/WorkspaceCaseViews.swift", "App/ProductViews.swift", "App/ImportPreparationViews.swift", "App/Info.plist", "App/SeeSoundApp.swift", "App/RootView.swift",
                                     "App/AudioProbes.swift", "App/AppleSoundClassifier.swift", "App/HandProbe.swift",
                                     "App/ClassificationResultsSubject.swift", "App/ExperienceViews.swift", "App/ConversationViews.swift",
                                     "Shared/ConnectivityBridge.swift", "App/OpenSourceSupport.swift", "App/LibraryViews.swift",
                                     "App/OfflineSpeechBridge.swift", "App/SignalMonitor.swift", "App/DashboardViews.swift",
                                     "App/ExperimentServices.swift", "App/ExperimentViews.swift", 
                                      "App/ReminderService.swift", "App/TextSharingService.swift", "App/DailyViews.swift", "App/DailyFlowViews.swift", "App/AssistanceViews.swift", "App/RoutineViews.swift", "App/CasePreparationViews.swift", "App/ContinuityViews.swift", "App/QualityViews.swift", "App/WorkroomViews.swift", "App/WorkroomCasesViews.swift", "App/BilingualViews.swift", "App/IntelligenceViews.swift", "App/EnvironmentalViews.swift", "App/EnvironmentalLiveService.swift", "Server", "Training"],
                sources: ["App/CampusWorkspaceDomain.swift", "App/CampusEvaluationDomain.swift", "App/ModelUpgradeDomain.swift", "App/CampusDomain.swift", "App/CaseEfficiencyDomain.swift", "App/RecoveryExperienceDomain.swift", "App/WorkspaceUpgradeDomain.swift", "App/WorkspaceUpgradeService.swift", "Shared/WatchLinkDomain.swift", "App/ProductDomain.swift", "Shared/ShareInbox.swift", "App/ContinuityDomain.swift", "App/QualityDomain.swift", "App/ContinuityService.swift", "Shared/AgendaHandoffDomain.swift", "App/CasePreparation.swift", "App/WorkroomDomain.swift", "App/WorkroomService.swift", "App/WorkroomImport.swift", "App/IntelligenceDomain.swift", "App/IntelligenceService.swift", "App/EnvironmentalDomain.swift", "App/EnvironmentalModel.swift", "App/EnvironmentalService.swift", "Shared/EventDomain.swift", "App/ConversationDomain.swift", "App/LocalJournal.swift",
                          "App/RoutineDomain.swift", "App/RoutineService.swift", "App/AssistanceDomain.swift", "App/AssistanceService.swift", "App/DailyDomain.swift", "App/DailyFlowDomain.swift", "App/SharingDomain.swift", "App/DatabaseJournal.swift", "App/LibraryDomain.swift", "App/ExperimentDomain.swift", "App/SampleAudioReader.swift", "App/PublicExperimentDomain.swift"]),
        .testTarget(name: "SeeSoundDataTests", dependencies: ["SeeSoundData", .product(name: "GRDB", package: "GRDB.swift")],
                    path: "Checks", sources: ["Integration/CampusWorkspaceTests.swift", "Integration/CampusTests.swift", "Integration/ModelUpgradeTests.swift", "Integration/CaseEfficiencyTests.swift", "Integration/RecoveryExperienceTests.swift", "Integration/WorkspaceUpgradeTests.swift", "Integration/ProductTests.swift", "Integration/ContinuityTests.swift", "Integration/CasePreparationTests.swift", "Integration/WorkroomIntegrationTests.swift", "Integration/IntelligenceIntegrationTests.swift", "Integration/EnvironmentalIntegrationTests.swift", "Integration/RoutineIntegrationTests.swift", "Integration/AssistanceIntegrationTests.swift", "Integration/DataIntegrationTests.swift", "Integration/DailyIntegrationTests.swift", "Integration/DailyFlowIntegrationTests.swift", "CoreChecks.swift",
                                              "JournalChecks.swift", "WatchLinkChecks.swift", "ConversationChecks.swift"],
                    resources: [.copy("Fixtures")])
    ]
)
