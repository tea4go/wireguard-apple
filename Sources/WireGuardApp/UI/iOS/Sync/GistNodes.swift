// SPDX-License-Identifier: MIT

import Foundation

struct GistNode: Equatable {
    static let defaultFile = "default"
    static let legacyFile = "wireguard-harmony-sync.conf"

    let name: String
    let peer: PeerConfiguration
    let privateKey: PrivateKey?

    var id: String { peer.publicKey.base64Key }
    var addresses: String { peer.allowedIPs.map(\.stringRepresentation).joined(separator: ", ") }

    init(name: String, peer: PeerConfiguration, privateKey: PrivateKey? = nil) {
        self.name = name
        self.peer = peer
        self.privateKey = privateKey
    }

    static func peers(in config: TunnelConfiguration) -> [GistNode] {
        return config.peers.map { peer in
            GistNode(name: peer.allowedIPs.first?.stringRepresentation ?? peer.publicKey.base64Key, peer: peer)
        }
    }

    static func interface(in config: TunnelConfiguration) -> GistNode? {
        guard let firstAddress = config.interface.addresses.first else { return nil }
        let key = config.interface.privateKey
        var peer = PeerConfiguration(publicKey: key.publicKey)
        peer.allowedIPs = config.interface.addresses
        return GistNode(name: firstAddress.stringRepresentation, peer: peer, privateKey: key)
    }

    static func decode(_ text: String) throws -> [GistNode] {
        var sections: [[String: String]] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.lowercased() == "[peer]" {
                sections.append([:])
                continue
            }
            let fields = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard sections.count > 0, fields.count == 2 else { throw GistSyncError.invalidNodeFile }
            let key = fields[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = fields[1].trimmingCharacters(in: .whitespaces)
            let index = sections.count - 1
            guard ["name", "publickey", "privatekey", "allowedips", "endpoint", "persistentkeepalive", "presharedkey"].contains(key),
                  sections[index].updateValue(value, forKey: key) == nil else { throw GistSyncError.invalidNodeFile }
        }

        let nodes: [GistNode] = try sections.map { fields in
            guard let name = fields["name"], !name.isEmpty, let rawKey = fields["publickey"],
                  let key = PublicKey(base64Key: rawKey), let addresses = fields["allowedips"] else {
                throw GistSyncError.invalidNodeFile
            }
            var peer = PeerConfiguration(publicKey: key)
            peer.allowedIPs = try addresses.split(separator: ",", omittingEmptySubsequences: false).map {
                guard let address = IPAddressRange(from: $0.trimmingCharacters(in: .whitespaces)) else {
                    throw GistSyncError.invalidNodeFile
                }
                return address
            }
            if let endpoint = fields["endpoint"], !endpoint.isEmpty {
                guard let parsed = Endpoint(from: endpoint) else { throw GistSyncError.invalidNodeFile }
                peer.endpoint = parsed
            }
            if let keepalive = fields["persistentkeepalive"] {
                guard let parsed = UInt16(keepalive) else { throw GistSyncError.invalidNodeFile }
                peer.persistentKeepAlive = parsed
            }
            if let key = fields["presharedkey"], !key.isEmpty {
                guard let parsed = PreSharedKey(base64Key: key) else { throw GistSyncError.invalidNodeFile }
                peer.preSharedKey = parsed
            }
            var privateKey: PrivateKey?
            if let secret = fields["privatekey"], !secret.isEmpty {
                guard let parsed = PrivateKey(base64Key: secret), parsed.publicKey == key else {
                    throw GistSyncError.invalidNodeFile
                }
                privateKey = parsed
            }
            return GistNode(name: name, peer: peer, privateKey: privateKey)
        }
        return nodes
    }

    static func encode(_ nodes: [GistNode]) throws -> String {
        return try nodes.map { node in
            guard !node.peer.allowedIPs.isEmpty else { throw GistSyncError.invalidNodeFile }
            var lines = ["[Peer]", "Name = " + node.name, "PublicKey = " + node.id]
            if let key = node.privateKey { lines.append("PrivateKey = " + key.base64Key) }
            lines.append("AllowedIPs = " + node.addresses)
            if let endpoint = node.peer.endpoint { lines.append("Endpoint = " + endpoint.stringRepresentation) }
            if let keepalive = node.peer.persistentKeepAlive { lines.append("PersistentKeepalive = \(keepalive)") }
            if let key = node.peer.preSharedKey { lines.append("PreSharedKey = " + key.base64Key) }
            return lines.joined(separator: "\n") + "\n"
        }.joined(separator: "\n")
    }
}

struct NodeComparison {
    enum Action: String, CaseIterable {
        case skip, upload, download, useAsInterface

        var title: String { tr("nodeSyncAction_" + rawValue) }
    }

    struct Item: Identifiable {
        let id: String
        let local: GistNode?
        let remote: GistNode?
        let isLocalInterface: Bool

        var title: String { local?.name ?? remote?.name ?? id }
        var matches: Bool {
            guard let local = local, let remote = remote else { return false }
            if isLocalInterface {
                return Set(local.peer.allowedIPs) == Set(remote.peer.allowedIPs) && remote.privateKey != nil
            }
            return local.peer == remote.peer
        }

        var actions: [Action] {
            if matches { return [.skip] }
            var result: [Action] = [.skip]
            if local != nil { result.append(.upload) }
            if remote != nil { result.append(.download) }
            if local == nil && remote?.privateKey != nil { result.append(.useAsInterface) }
            return result
        }
    }

    let local: TunnelConfiguration?
    let remote: [GistNode]
    let items: [Item]

    init(local: TunnelConfiguration?, remote: [GistNode]) {
        self.local = local
        self.remote = remote
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var localByID: [String: GistNode] = [:]
        let interfaceNode = local.flatMap(GistNode.interface(in:))
        if let local = local {
            for peer in GistNode.peers(in: local) { localByID[peer.id] = peer }
        }
        if let interfaceNode = interfaceNode { localByID[interfaceNode.id] = interfaceNode }
        self.items = Set(localByID.keys).union(remoteByID.keys).map { id in
            Item(id: id, local: localByID[id], remote: remoteByID[id], isLocalInterface: id == interfaceNode?.id)
        }.sorted { (left, right) in
            let order = left.title.localizedStandardCompare(right.title)
            return order == .orderedSame ? left.id < right.id : order == .orderedAscending
        }
    }

    struct Plan {
        let remoteContent: String?
        let localConfiguration: TunnelConfiguration?
    }

    func plan(actions: [String: Action], newTunnelName: String) throws -> Plan {
        var remoteNodes = remote
        var peers = local?.peers ?? []
        var interface = local?.interface
        var chosenInterface: GistNode?
        var downloadedPeers: [GistNode] = []

        for item in items {
            switch actions[item.id] ?? .skip {
            case .skip: break
            case .upload:
                guard let node = item.local else { throw GistSyncError.invalidNodeFile }
                if let index = remoteNodes.lastIndex(where: { $0.id == node.id }) {
                    // A local peer cannot supply the remote node's private key.
                    let existing = remoteNodes[index]
                    remoteNodes[index] = GistNode(name: node.name, peer: node.peer,
                                                  privateKey: node.privateKey ?? existing.privateKey)
                } else {
                    remoteNodes.append(node)
                }
            case .download:
                guard let node = item.remote else { throw GistSyncError.invalidNodeFile }
                if item.isLocalInterface {
                    interface?.addresses = node.peer.allowedIPs
                } else {
                    downloadedPeers.append(node)
                }
            case .useAsInterface:
                guard chosenInterface == nil, let node = item.remote, node.privateKey != nil else {
                    throw GistSyncError.invalidNodeFile
                }
                chosenInterface = node
            }
        }

        if let selected = chosenInterface, let privateKey = selected.privateKey {
            var replacement = interface ?? InterfaceConfiguration(privateKey: privateKey)
            replacement.privateKey = privateKey
            replacement.addresses = selected.peer.allowedIPs
            interface = replacement
            peers.removeAll { $0.publicKey == privateKey.publicKey }
        } else if interface == nil, let first = downloadedPeers.first {
            var newInterface = InterfaceConfiguration(privateKey: PrivateKey())
            newInterface.addresses = Array(first.peer.allowedIPs.prefix(1))
            interface = newInterface
        }
        for node in downloadedPeers {
            if let index = peers.firstIndex(where: { $0.publicKey == node.peer.publicKey }) {
                peers[index] = node.peer
            } else {
                peers.append(node.peer)
            }
        }

        let configuration = interface.map {
            TunnelConfiguration(name: local?.name ?? newTunnelName, interface: $0, peers: peers)
        }
        return Plan(remoteContent: remoteNodes == remote ? nil : try GistNode.encode(remoteNodes),
                    localConfiguration: configuration == local ? nil : configuration)
    }
}
