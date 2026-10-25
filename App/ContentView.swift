import BlueDuckKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: DomainController
    @State private var selection: String?
    @State private var draft: DomainConfig?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(controller.configs) { config in
                    Label(config.displayName, systemImage: "externaldrive.connected.to.line.below")
                        .tag(config.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .toolbar {
                Button {
                    let config = DomainConfig()
                    draft = config
                    selection = nil
                } label: {
                    Label("Add Bucket", systemImage: "plus")
                }
            }
        } detail: {
            if let draft {
                ConfigEditor(config: draft, isNew: true) { self.draft = nil }
                    .id(draft.id)
            } else if let id = selection, let config = controller.configs.first(where: { $0.id == id }) {
                ConfigEditor(config: config, isNew: false) { selection = nil }
                    .id(config.id)
            } else {
                ContentUnavailableView(
                    "No Bucket Selected",
                    systemImage: "externaldrive.badge.icloud",
                    description: Text("Add an S3 bucket to see it under Locations in the Finder sidebar.\nRight-click any file or folder there and choose Keep Offline to cache it.")
                )
            }
        }
        .alert("BlueDuck", isPresented: Binding(get: { controller.lastError != nil }, set: { if !$0 { controller.lastError = nil } })) {
            Button("OK") { controller.lastError = nil }
        } message: {
            Text(controller.lastError ?? "")
        }
    }
}

private struct ConfigEditor: View {
    @EnvironmentObject private var controller: DomainController
    @State var config: DomainConfig
    let isNew: Bool
    let onDone: () -> Void

    @State private var secret = ""
    @State private var status: String?
    @State private var busy = false
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section("Bucket") {
                TextField("Name", text: $config.displayName, prompt: Text("Shown in the Finder sidebar"))
                TextField("Bucket", text: $config.bucket)
                TextField("Folder in bucket", text: $config.rootPrefix, prompt: Text("Optional, e.g. team/shared"))
                TextField("Region", text: $config.region)
            }
            Section {
                TextField("Endpoint", text: $config.endpoint, prompt: Text("Leave empty for AWS S3"))
                Toggle("Path-style addressing", isOn: $config.pathStyle)
            } header: {
                Text("S3-compatible service")
            } footer: {
                Text("For MinIO, Cloudflare R2, Wasabi and similar services. Most self-hosted servers need path-style addressing.")
            }
            Section {
                TextField("Access key ID", text: $config.accessKeyID)
                SecureField("Secret access key", text: $secret)
            } header: {
                Text("Credentials")
            } footer: {
                Text("The secret is stored in your Keychain. Use a key scoped to this bucket.")
            }

            if let status {
                Text(status).foregroundStyle(.secondary)
            }

            HStack {
                if !isNew {
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                    Button("Show in Finder") { Task { await controller.revealInFinder(config) } }
                }
                Spacer()
                Button("Test Connection") {
                    run { status = await controller.testConnection(config, secret: secret) }
                }
                Button(isNew ? "Add" : "Save") {
                    run {
                        await controller.save(config, secret: secret)
                        if controller.lastError == nil {
                            status = "Saved."
                            if isNew { onDone() }
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .disabled(busy)
        }
        .formStyle(.grouped)
        .navigationTitle(isNew ? "New Bucket" : config.displayName)
        .onAppear { secret = controller.secret(for: config) }
        .confirmationDialog("Remove \(config.displayName)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                run {
                    await controller.remove(config)
                    onDone()
                }
            }
        } message: {
            Text("The bucket disappears from Finder and offline copies are deleted from this Mac. Nothing is deleted from S3.")
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        busy = true
        Task {
            await work()
            busy = false
        }
    }
}
