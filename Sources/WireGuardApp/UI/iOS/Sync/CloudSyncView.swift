// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

@MainActor
struct CloudSyncView: View {
    let provider: GistProvider
    let nodeSync: Bool
    let tunnels: TunnelsManager

    @State private var credentials = GistCredentials()
    @State private var loadedCredentials: GistCredentials?
    @State private var gist: Gist?
    @State private var busy = false
    @State private var confirmation: Confirmation?
    @State private var message: String?
    @State private var backupToRestore: [TunnelConfiguration] = []
    @State private var nodeFiles: [String: String] = [:]
    @State private var selectedFile = GistNode.defaultFile
    @State private var selectedTunnel = ""
    @State private var comparison: NodeComparison?
    @State private var actions: [String: NodeComparison.Action] = [:]
    @State private var didLoadCredentials = false
    private static var operationInProgress = false

    private enum Confirmation: Identifiable {
        case upload, restore, delete(String), createNodeGist, applyNodes

        var id: String { title }

        var isDeletion: Bool {
            if case .delete = self { return true }
            return false
        }

        var title: String {
            switch self {
            case .upload: return tr("cloudSyncUpload")
            case .restore: return tr("cloudSyncRestore")
            case .delete: return tr("cloudSyncDelete")
            case .createNodeGist: return tr("nodeSyncCreateGist")
            case .applyNodes: return tr("nodeSyncApply")
            }
        }
    }

    var body: some View {
        Form {
            Section(header: Text(provider.title)) {
                SecureField(tr("cloudSyncToken"), text: $credentials.token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField(tr("cloudSyncGistID"), text: $credentials.id)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                Button(tr("cloudSyncSave")) {
                    run {
                        let value = try credentials.normalized()
                        try value.save(for: provider)
                        message = tr("cloudSyncSettingsSaved")
                    }
                }
            }
            if nodeSync {
                nodeSections
            } else {
                backupSections
            }
            if busy { ProgressView() }
        }
        .disabled(busy)
        .onAppear {
            guard !didLoadCredentials else { return }
            didLoadCredentials = true
            do {
                credentials = try GistCredentials.load(for: provider)
            } catch {
                message = error.localizedDescription
            }
        }
        .onChange(of: credentials.id) { _ in clearIfCredentialsChanged() }
        .onChange(of: credentials.token) { _ in clearIfCredentialsChanged() }
        .onChange(of: selectedTunnel) { _ in updateComparison() }
        .onChange(of: selectedFile) { _ in updateComparison() }
        .confirmationDialog(confirmation?.title ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
                            titleVisibility: .visible, presenting: confirmation) { item in
            Button(item.title, role: item.isDeletion ? .destructive : nil) { confirm(item) }
            Button(tr("cloudSyncCancel"), role: .cancel) { confirmation = nil }
        } message: { item in
            Text(confirmationText(item))
        }
        .alert(tr("cloudSyncStatus"), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button(tr("cloudSyncOK"), role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    @ViewBuilder private var backupSections: some View {
        Section(footer: Text(provider == .github ? tr("cloudSyncGitHubNotice") : tr("cloudSyncGiteeNotice"))) {
            Button(tr("cloudSyncUpload")) { confirmation = .upload }
            Button(tr("cloudSyncLoadVersions")) { run { try await loadBackups() } }
        }
        if let gist = gist {
            Section(header: Text(tr("cloudSyncVersions"))) {
                let names = TunnelBackup.filenames(in: gist)
                if names.isEmpty { Text(tr("cloudSyncNoBackups")).foregroundColor(.secondary) }
                forEachBackup(names)
            }
        }
    }

    private func forEachBackup(_ names: [String]) -> some View {
        ForEach(names, id: \.self) { name in
            Menu {
                Button(tr("cloudSyncRestore")) {
                    run {
                        let client = try makeClient()
                        let latest = try await client.fetch()
                        guard let file = latest.files[name] else { throw GistSyncError.changedRemotely }
                        backupToRestore = try TunnelBackup.decode(try await client.read(file))
                        confirmation = .restore
                    }
                }
                Button(role: .destructive) { confirmation = .delete(name) } label: { Text(tr("cloudSyncDelete")) }
            } label: {
                HStack {
                    Text(name).multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    @ViewBuilder private var nodeSections: some View {
        Section(footer: Text(tr("nodeSyncHowTo"))) {
            Button(tr("nodeSyncCompare")) { run { try await loadNodes() } }
            if credentials.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && tunnels.numberOfTunnels() > 0 {
                Button(tr("nodeSyncCreateGist")) { confirmation = .createNodeGist }
            }
        }
        if let comparison = comparison {
            Section(header: Text(tr("nodeSyncSources"))) {
                Picker(tr("nodeSyncLocalTunnel"), selection: $selectedTunnel) {
                    Text(tr("nodeSyncNewTunnel")).tag("")
                    ForEach(tunnels.mapTunnels { $0.name }, id: \.self) { Text($0).tag($0) }
                }
                Picker(tr("nodeSyncRemoteFile"), selection: $selectedFile) {
                    ForEach(sortedNodeFilenames(), id: \.self) { Text($0).tag($0) }
                }
            }
            Section(header: Text(tr("nodeSyncComparison"))) {
                if comparison.items.isEmpty { Text(tr("nodeSyncEmpty")).foregroundColor(.secondary) }
                ForEach(comparison.items) { item in
                    DisclosureGroup {
                        if let local = item.local { nodeDetails(local, label: tr("nodeSyncLocal")) }
                        if let remote = item.remote { nodeDetails(remote, label: tr("nodeSyncRemote")) }
                        if !item.matches {
                            Picker(tr("nodeSyncAction"), selection: Binding(
                                get: { actions[item.id] ?? .skip },
                                set: { actions[item.id] = $0 })) {
                                    ForEach(item.actions, id: \.self) { Text($0.title).tag($0) }
                                }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                            Text(nodeStatus(item)).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
            Button(tr("nodeSyncApply")) { confirmation = .applyNodes }
                .disabled(!actions.values.contains { $0 != .skip })
        }
    }

    private func nodeStatus(_ item: NodeComparison.Item) -> String {
        if item.matches { return tr("nodeSyncIdentical") }
        if item.isLocalInterface { return tr("nodeSyncLocalInterface") }
        if item.local == nil { return tr("nodeSyncRemoteOnly") }
        if item.remote == nil { return tr("nodeSyncLocalOnly") }
        return tr("nodeSyncDifferent")
    }

    private func nodeDetails(_ node: GistNode, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline.weight(.semibold))
            Text(tr(format: "nodeSyncAllowedIPs %@", node.addresses))
            if let endpoint = node.peer.endpoint {
                Text(tr(format: "nodeSyncEndpoint %@", endpoint.stringRepresentation))
            }
            if let keepAlive = node.peer.persistentKeepAlive {
                Text(tr(format: "nodeSyncKeepAlive %d", Int(keepAlive)))
            }
            if node.peer.preSharedKey != nil { Text(tr("nodeSyncHasPSK")) }
            if node.privateKey != nil { Text(tr("nodeSyncHasPrivateKey")) }
        }
        .font(.footnote)
        .padding(.vertical, 4)
    }

    private func confirmationText(_ item: Confirmation) -> String {
        switch item {
        case .upload:
            return provider == .github ? tr("cloudSyncGitHubNotice") : tr("cloudSyncGiteeNotice")
        case .restore:
            let replacements = backupToRestore.filter { config in
                config.name.flatMap(tunnels.tunnel(named:)) != nil
            }.count
            return tr(format: "cloudSyncConfirmRestore %d %d", backupToRestore.count, replacements)
        case .delete(let name):
            return tr(format: "cloudSyncConfirmDelete %@", name)
        case .createNodeGist:
            return tr("nodeSyncConfirmCreate")
        case .applyNodes:
            return tr("nodeSyncConfirmApply")
        }
    }

    private func confirm(_ item: Confirmation) {
        switch item {
        case .upload:
            PrivateDataConfirmation.confirmAccess(to: tr("cloudSyncAuthenticate")) { run { try await uploadBackup() } }
        case .restore:
            let configurations = backupToRestore
            backupToRestore = []
            run { try await restore(configurations) }
        case .delete(let name):
            run {
                let client = try makeClient()
                let latest = try await client.fetch()
                guard TunnelBackup.filenames(in: latest).contains(name) else { throw GistSyncError.changedRemotely }
                gist = try await client.removeFile(named: name)
            }
        case .createNodeGist:
            PrivateDataConfirmation.confirmAccess(to: tr("cloudSyncAuthenticate")) { run { try await createNodeGist() } }
        case .applyNodes:
            if actions.values.contains(.upload) {
                PrivateDataConfirmation.confirmAccess(to: tr("cloudSyncAuthenticate")) { run { try await applyNodes() } }
            } else {
                run { try await applyNodes() }
            }
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !Self.operationInProgress else {
            message = tr("cloudSyncInProgress")
            return
        }
        Self.operationInProgress = true
        busy = true
        Task { @MainActor in
            defer {
                busy = false
                Self.operationInProgress = false
            }
            do {
                try await operation()
            } catch is DecodingError {
                message = GistSyncError.unexpectedResponse.localizedDescription
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func makeClient() throws -> GistClient {
        let value = try credentials.normalized()
        guard !value.token.isEmpty else { throw GistSyncError.credentials }
        return GistClient(provider: provider, credentials: value)
    }

    private func clearIfCredentialsChanged() {
        guard let loaded = loadedCredentials,
              (try? credentials.normalized()) != loaded else { return }
        gist = nil
        nodeFiles = [:]
        comparison = nil
        actions = [:]
        backupToRestore = []
        loadedCredentials = nil
    }

    private func loadBackups() async throws {
        let client = try makeClient()
        gist = try await client.fetch()
        loadedCredentials = client.credentials
    }

    private func uploadBackup() async throws {
        let client = try makeClient()
        let configurations = try tunnels.mapTunnels { tunnel in
            guard let configuration = tunnel.tunnelConfiguration else { throw GistSyncError.invalidBackup }
            return configuration
        }
        let date = Date()
        let backup = try TunnelBackup(configurations: configurations, date: date)
        let content = try backup.encode()
        var file = TunnelBackup.filename(date: date, byteCount: content.utf8.count)
        if !client.credentials.id.isEmpty {
            let latest = try await client.fetch()
            var timestamp = date
            while latest.files[file] != nil {
                timestamp.addTimeInterval(1)
                file = TunnelBackup.filename(date: timestamp, byteCount: content.utf8.count)
            }
        }
        let model = UIDevice.current.model
        let response = try await client.write(file: file, content: content, description: "wg|\(model)|\(model)|\(model)")
        try remember(response, token: client.credentials.token)
        message = tr(format: "cloudSyncUploaded %d", configurations.count)
    }

    private func remember(_ response: Gist, token: String) throws {
        let value = GistCredentials(token: token, id: response.id)
        credentials = value
        loadedCredentials = value
        gist = response
        try value.save(for: provider)
    }

    private func restore(_ configurations: [TunnelConfiguration]) async throws {
        var completed = 0
        for configuration in configurations {
            do {
                try await save(configuration)
                completed += 1
            } catch {
                message = tr(format: "cloudSyncPartialRestore %d %@", completed, error.localizedUIString)
                return
            }
        }
        message = tr(format: "cloudSyncRestored %d", completed)
    }

    private func save(_ configuration: TunnelConfiguration) async throws {
        guard let name = configuration.name else { throw GistSyncError.invalidBackup }
        if let tunnel = tunnels.tunnel(named: name) {
            guard tunnel.tunnelConfiguration != configuration else { return }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                tunnels.modify(tunnel: tunnel, tunnelConfiguration: configuration, onDemandOption: tunnel.onDemandOption) { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } else {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TunnelContainer, Error>) in
                tunnels.add(tunnelConfiguration: configuration) { continuation.resume(with: $0) }
            }
        }
    }

    private func sortedNodeFilenames() -> [String] {
        let files = nodeFiles.keys.sorted()
        return files.contains(GistNode.defaultFile) || files.isEmpty
            ? [GistNode.defaultFile] + files.filter { $0 != GistNode.defaultFile } : files
    }

    private func createNodeGist() async throws {
        let client = try makeClient()
        guard client.credentials.id.isEmpty else { throw GistSyncError.changedRemotely }
        var nodes: [String: GistNode] = [:]
        for tunnel in tunnels.mapTunnels(transform: { $0 }) {
            guard let config = tunnel.tunnelConfiguration else { throw GistSyncError.invalidNodeFile }
            for peer in GistNode.peers(in: config) where nodes[peer.id] == nil { nodes[peer.id] = peer }
            if let interface = GistNode.interface(in: config) { nodes[interface.id] = interface }
        }
        guard !nodes.isEmpty else { throw GistSyncError.noTunnels }
        let content = try GistNode.encode(nodes.values.sorted { $0.id < $1.id })
        let response = try await client.write(file: GistNode.defaultFile, content: content, description: "wg-connect-node-sync")
        try remember(response, token: client.credentials.token)
        try await loadNodes()
        message = tr("nodeSyncCreatedGist")
    }

    private func loadNodes() async throws {
        let client = try makeClient()
        var files: [String: String] = [:]
        if !client.credentials.id.isEmpty {
            let latest = try await client.fetch()
            let backups = Set(TunnelBackup.filenames(in: latest))
            for (name, file) in latest.files where !backups.contains(name) {
                let content = try await client.read(file)
                if let nodes = try? GistNode.decode(content), !nodes.isEmpty {
                    files[name] = content
                } else if name == GistNode.defaultFile || name == GistNode.legacyFile {
                    guard content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw GistSyncError.invalidNodeFile
                    }
                    files[name] = content
                }
            }
            gist = latest
        }
        loadedCredentials = client.credentials
        nodeFiles = files
        let preferred = [GistNode.defaultFile, GistNode.legacyFile].first { files[$0] != nil }
        selectedFile = preferred ?? sortedNodeFilenames()[0]
        selectedTunnel = tunnels.numberOfTunnels() == 1 ? tunnels.tunnel(at: 0).name : ""
        updateComparison()
    }

    private func updateComparison() {
        guard loadedCredentials != nil, nodeSync else { return }
        let local = tunnels.tunnel(named: selectedTunnel)?.tunnelConfiguration
        if !selectedTunnel.isEmpty && local == nil {
            comparison = nil
            message = GistSyncError.changedLocally.localizedDescription
            return
        }
        let remote = (try? GistNode.decode(nodeFiles[selectedFile] ?? "")) ?? []
        comparison = NodeComparison(local: local, remote: remote)
        actions = [:]
    }

    private func applyNodes() async throws {
        guard let comparison = comparison else { return }
        let client = try makeClient()
        var newName = selectedFile
        var suffix = 2
        while tunnels.tunnel(named: newName) != nil {
            newName = "\(selectedFile) (\(suffix))"
            suffix += 1
        }
        let plan = try comparison.plan(actions: actions, newTunnelName: newName)
        if !client.credentials.id.isEmpty {
            let latest = try await client.fetch()
            let latestContent: String?
            if let file = latest.files[selectedFile] {
                latestContent = try await client.read(file)
            } else {
                latestContent = nil
            }
            guard latestContent == nodeFiles[selectedFile] else { throw GistSyncError.changedRemotely }
        }
        guard comparison.local == tunnels.tunnel(named: selectedTunnel)?.tunnelConfiguration else {
            throw GistSyncError.changedLocally
        }
        if let configuration = plan.localConfiguration {
            try await save(configuration)
        }
        if let content = plan.remoteContent {
            do {
                let response = try await client.write(file: selectedFile, content: content, description: "wg-connect-node-sync")
                try remember(response, token: client.credentials.token)
                nodeFiles[selectedFile] = content
            } catch {
                if plan.localConfiguration != nil {
                    updateComparison()
                    message = tr(format: "nodeSyncPartialApply %@", error.localizedDescription)
                    return
                }
                throw error
            }
        }
        updateComparison()
        message = tr("nodeSyncApplied")
    }
}
