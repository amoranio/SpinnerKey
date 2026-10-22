import SpinnerKeyCore
import SwiftUI

struct ConfigView: View {
    @StateObject private var model = ConfigModel()
    private let provider = ProviderKind.openRouter

    var body: some View {
        Form {
            managementKeySection
            scopeSection
            scheduleSection
            statusSection
        }
        .formStyle(.grouped)
        .disabled(model.busy)
    }

    private var managementKeySection: some View {
        Section {
            LabeledContent("Status") {
                Text(model.hasManagementKey(provider) ? "Stored in Keychain" : "Not set")
                    .foregroundStyle(model.hasManagementKey(provider) ? Color.green : Color.orange)
            }
            SecureField("Paste a new management key", text: $model.managementKeyInput)
                .onSubmit { model.saveManagementKey(for: provider) }
            HStack {
                Button("Save to Keychain") { model.saveManagementKey(for: provider) }
                    .disabled(model.managementKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Test") { Task { await model.testManagementKey(for: provider) } }
                    .disabled(!model.hasManagementKey(provider))
                Spacer()
                Button("Remove", role: .destructive) { model.removeManagementKey(for: provider) }
                    .disabled(!model.hasManagementKey(provider))
            }
        } header: {
            Text("\(provider.displayName) management key")
        } footer: {
            Text("Create one in OpenRouter → Settings → Management Keys. It can create and delete API keys but cannot call models. It is kept only in your Keychain and is never shown again.")
        }
    }

    private var scopeSection: some View {
        Section {
            Toggle("Rotate my \(provider.displayName) API key", isOn: model.jobEnabled(provider))
            Toggle("Update \(TargetKind.openCode.displayName) with each new key", isOn: model.target(.openCode, for: provider))
            LabeledContent("Credit limit per key (USD)") {
                TextField("No limit", text: $model.creditLimitText)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
                    .onSubmit { model.applyCreditLimit(for: provider) }
            }
        } header: {
            Text("What gets rotated")
        } footer: {
            Text("OpenCode's key is written to \(model.openCodeAuthFile.path). A credit limit caps what a leaked key could spend.")
        }
    }

    private var scheduleSection: some View {
        Section("Schedule") {
            Picker("Rotate every", selection: $model.config.intervalHours) {
                ForEach(Config.intervalPresets, id: \.self) { Text($0.label).tag($0.value) }
            }
            Picker("Revoke the old key", selection: $model.config.revokeGraceMinutes) {
                ForEach(Config.gracePresets, id: \.self) { Text($0.label).tag($0.value) }
            }
            Toggle("Notify me if a rotation fails", isOn: $model.config.notifyOnFailure)
            Toggle("Automatic rotation", isOn: model.scheduleEnabled)
        }
    }

    private var statusSection: some View {
        let job = model.state.jobs[provider.rawValue] ?? JobState()
        return Section("Status") {
            LabeledContent("Last rotated", value: job.lastRotatedAt.map(format) ?? "Never")
            LabeledContent("Next rotation") {
                if !model.config.scheduleEnabled {
                    Text("Automatic rotation is off")
                } else {
                    Text(Rotator.nextDue(job, config: model.config).map(format) ?? "At the next check")
                }
            }
            LabeledContent("Active key", value: job.activeKeyID.map { "\($0.prefix(12))…" } ?? "None issued by SpinnerKey yet")
            if !job.pendingRevocations.isEmpty {
                LabeledContent("Old keys awaiting revocation", value: "\(job.pendingRevocations.count)")
            }
            if let error = job.lastError {
                Text("Last error: \(error)").foregroundStyle(.red)
            }
            if job.activeKeyID == nil {
                Text("After the first rotation, delete the key you originally gave OpenCode in the OpenRouter dashboard. SpinnerKey only ever revokes keys it created.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Rotate now") { Task { await model.rotateNow() } }
                    .disabled(!model.hasManagementKey(provider))
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Refresh") { model.refresh() }
                Button("Open log") { model.openLog() }
            }
            if let message = model.message {
                Text(message).font(.callout)
            }
        }
    }

    private func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
