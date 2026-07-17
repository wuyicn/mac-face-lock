import Foundation

private enum SetupStoreError: Error {
    case unsupportedSchemaVersion
}

final class SetupStore {
    private let localStore: LocalJSONStore
    private let mode: AppEnvironmentMode

    private(set) var record: OnboardingRecord

    init(
        localStore: LocalJSONStore,
        mode: AppEnvironmentMode
    ) throws {
        self.localStore = localStore
        self.mode = mode
        self.record = localStore.readOnboarding()
        try enforceReleaseSafety(for: record)
    }

    func save(_ record: OnboardingRecord) throws {
        guard record.schemaVersion == 1 else {
            throw SetupStoreError.unsupportedSchemaVersion
        }
        try enforceReleaseSafety(for: record)
        try localStore.writeOnboarding(record)
        self.record = record
    }

    private func enforceReleaseSafety(for record: OnboardingRecord) throws {
        guard mode == .release,
              !record.isComplete,
              localStore.readControl().protectionEnabled else {
            return
        }
        _ = try localStore.writeControl(enabled: false)
    }
}
