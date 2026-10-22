import Foundation
import SpinnerKeyCore
import SwiftUI

@MainActor
final class ConfigModel: ObservableObject {
    @Published var config: Config {
        didSet { if config != oldValue { persist() } }
    }
    @Published private(set) var state = RotationState()
    @Published private(set) var managementKeyStored: [ProviderKind: Bool] = [:]
    @Published var managementKeyInput = ""
    @Published var creditLimitText = ""
    @Published private(set) var busy = false
    @Published var message: String?

    let store = Store()
    let secrets = KeychainStore()
    let agent = LaunchAgent()
    let openCodeAuthFile = OpenCodeTarget.defaultAuthFile()

    init() {
        let loaded = (try? store.loadConfig()) ?? .default
        config = loaded
        creditLimitText = loaded.job(for: .openRouter)?.creditLimit.map { String($0) } ?? ""
        refresh()
        // Keep the scheduler pointed at this copy of the app if it was moved.
        if loaded.scheduleEnabled, let executable = Bundle.main.executablePath {
            try? agent.install(executable: executable)
        }
    }

    func refresh() {
        do {
            state = try store.loadState()
        } catch {
            message = error.localizedDescription
        }
        for provider in ProviderKind.allCases {
            managementKeyStored[provider] = secrets.contains(account: provider.managementKeyAccount)
        }
    }

    func hasManagementKey(_ provider: ProviderKind) -> Bool {
        managementKeyStored[provider] ?? false
    }

    // MARK: Management key

    func saveManagementKey(for provider: ProviderKind) {
        let key = managementKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        managementKeyInput = ""
        guard !key.isEmpty else { return }
        do {
            try secrets.write(key, account: provider.managementKeyAccount)
            message = "Management key saved to the Keychain."
        } catch {
            message = "Could not save to the Keychain: \(error.localizedDescription)"
        }
        refresh()
    }

    func removeManagementKey(for provider: ProviderKind) {
        do {
            try secrets.delete(account: provider.managementKeyAccount)
            message = "Management key removed from the Keychain."
        } catch {
            message = error.localizedDescription
        }
        refresh()
    }

    func testManagementKey(for provider: ProviderKind) async {
        busy = true
        defer { busy = false }
        do {
            let key = try secrets.read(account: provider.managementKeyAccount) ?? ""
            switch provider {
            case .openRouter: try await OpenRouterProvider(managementKey: key).checkManagementKey()
            }
            message = "\(provider.displayName) accepted the management key."
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Scope

    func jobEnabled(_ provider: ProviderKind) -> Binding<Bool> {
        Binding(get: { self.config.job(for: provider)?.enabled ?? false },
                set: { value in self.updateJob(provider) { $0.enabled = value } })
    }

    func target(_ target: TargetKind, for provider: ProviderKind) -> Binding<Bool> {
        Binding(get: { self.config.job(for: provider)?.targets.contains(target) ?? false },
                set: { value in
                    self.updateJob(provider) { job in
                        job.targets.removeAll { $0 == target }
                        if value { job.targets.append(target) }
                    }
                })
    }

    func applyCreditLimit(for provider: ProviderKind) {
        let text = creditLimitText.trimmingCharacters(in: .whitespaces)
        let limit = Double(text).flatMap { $0 > 0 ? $0 : nil }
        if !text.isEmpty && limit == nil {
            message = "Credit limit must be a positive number, or empty for no limit."
            return
        }
        updateJob(provider) { $0.creditLimit = limit }
    }

    private func updateJob(_ provider: ProviderKind, _ change: (inout RotationJob) -> Void) {
        if let index = config.jobs.firstIndex(where: { $0.provider == provider }) {
            change(&config.jobs[index])
        } else {
            var job = RotationJob(provider: provider, enabled: false, targets: [])
            change(&job)
            config.jobs.append(job)
        }
    }

    // MARK: Schedule

    var scheduleEnabled: Binding<Bool> {
        Binding(get: { self.config.scheduleEnabled }, set: { self.setSchedule($0) })
    }

    private func setSchedule(_ enabled: Bool) {
        do {
            if enabled {
                guard let executable = Bundle.main.executablePath else { return }
                try agent.install(executable: executable)
                message = ProviderKind.allCases.contains { hasManagementKey($0) }
                    ? "Automatic rotation is on."
                    : "Automatic rotation is on, but no management key is stored yet."
            } else {
                try agent.uninstall()
                message = "Automatic rotation is off."
            }
            config.scheduleEnabled = enabled
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Actions

    func rotateNow() async {
        busy = true
        defer { busy = false; refresh() }
        do {
            let report = try await Wiring.makeRotator(store: store, secrets: secrets).run(force: true)
            if let failure = report.failures.first {
                message = "Rotation failed: \(failure.message) OpenCode still has its previous key."
            } else if report.rotated.isEmpty {
                message = "Nothing to rotate. Enable a key under \"What gets rotated\"."
            } else {
                message = "Rotated \(report.rotated.map(\.displayName).joined(separator: ", ")). Restart running OpenCode sessions to pick up the new key."
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func openLog() {
        NSWorkspace.shared.open(store.paths.logFile)
    }

    private func persist() {
        do {
            try store.saveConfig(config)
        } catch {
            message = "Could not save settings: \(error.localizedDescription)"
        }
    }
}
