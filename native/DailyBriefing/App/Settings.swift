import Observation
import Foundation
import SwiftUI

@MainActor @Observable final class SettingsStore {
    private let persistence: PreferencesPersistence
    private var stored: AppPreferences
    private(set) var sourceVersions: [String: UUID]
    private(set) var annotations: AnnotationLedger
    private(set) var recoveryRequired: Bool
    private(set) var recoveryNotice: String?
    @ObservationIgnored var onChange: ((AppPreferences, AppPreferences) -> Void)?
    var value: AppPreferences {
        get { stored }
        set {
            let old = stored
            persistence.save(newValue); synchronize()
            onChange?(old, stored)
        }
    }
    init(defaults: UserDefaults = .standard) {
        let repository = PreferencesPersistence(defaults: defaults); persistence = repository
        stored = repository.document.preferences; sourceVersions = repository.document.sourceVersions
        annotations = repository.document.annotations
        recoveryRequired = repository.recoveryRequired; recoveryNotice = repository.notice
    }
    var annotationsSeeded: Bool { persistence.document.annotationsSeeded }
    func seedAnnotations(_ snapshots: [BriefingSnapshot]) { persistence.seedAnnotations(snapshots); synchronize() }
    func recordAnnotations(_ snapshot: BriefingSnapshot) { persistence.recordAnnotations(snapshot); synchronize() }
    func invalidate(_ kinds: Set<SectionKind>) { persistence.invalidate(kinds); synchronize() }
    func restoreLastGood() {
        let old = stored
        if persistence.restoreLastGood() { synchronize(); onChange?(old, stored) }
        else { synchronize() }
    }
    func keepCurrentSettings() {
        let old = stored; persistence.keepCurrent(); synchronize(); onChange?(old, stored)
    }
    private func synchronize() {
        stored = persistence.document.preferences; sourceVersions = persistence.document.sourceVersions
        annotations = persistence.document.annotations
        recoveryRequired = persistence.recoveryRequired; recoveryNotice = persistence.notice
    }
}
