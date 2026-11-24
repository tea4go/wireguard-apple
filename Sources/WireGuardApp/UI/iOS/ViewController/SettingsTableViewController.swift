// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import UIKit
import SwiftUI
import os.log

class SettingsTableViewController: UITableViewController {

    enum SettingsFields {
        case about
        case exportZipArchive
        case viewLog
        case language
        case giteeBackup
        case githubBackup
        case giteeNodes

        var localizedUIString: String {
            switch self {
            case .about: return tr("settingsSectionTitleAbout")
            case .exportZipArchive: return tr("settingsExportZipButtonTitle")
            case .viewLog: return tr("settingsViewLogButtonTitle")
            case .language: return tr("iosAppLanguage")
            case .giteeBackup: return tr("cloudSyncGiteeBackup")
            case .githubBackup: return tr("cloudSyncGitHubBackup")
            case .giteeNodes: return tr("nodeSyncTitle")
            }
        }
    }

    let settingsFieldsBySection: [[SettingsFields]] = [
        [.language, .viewLog, .exportZipArchive],
        [.giteeBackup, .githubBackup, .giteeNodes],
        [.about]
    ]

    let tunnelsManager: TunnelsManager?

    init(tunnelsManager: TunnelsManager?) {
        self.tunnelsManager = tunnelsManager
        super.init(style: .insetGrouped)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = tr("settingsViewTitle")

        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension
        tableView.register(ButtonCell.self)
    }

    func exportConfigurationsAsZipFile(sourceView: UIView) {
        PrivateDataConfirmation.confirmAccess(to: tr("iosExportPrivateData")) { [weak self] in
            guard let self = self else { return }
            guard let tunnelsManager = self.tunnelsManager else { return }
            guard let destinationDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

            let destinationURL = destinationDir.appendingPathComponent("wireguard-export.zip")
            _ = FileManager.deleteFile(at: destinationURL)

            let count = tunnelsManager.numberOfTunnels()
            let tunnelConfigurations = (0 ..< count).compactMap { tunnelsManager.tunnel(at: $0).tunnelConfiguration }
            ZipExporter.exportConfigFiles(tunnelConfigurations: tunnelConfigurations, to: destinationURL) { [weak self] error in
                if let error = error {
                    ErrorPresenter.showErrorAlert(error: error, from: self)
                    return
                }

                let fileExportVC = UIDocumentPickerViewController(url: destinationURL, in: .exportToService)
                self?.present(fileExportVC, animated: true, completion: nil)
            }
        }
    }

    func presentLogView() {
        let logVC = LogViewController()
        navigationController?.pushViewController(logVC, animated: true)

    }
}

extension SettingsTableViewController {
    override func numberOfSections(in tableView: UITableView) -> Int {
        return settingsFieldsBySection.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return settingsFieldsBySection[section].count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let field = settingsFieldsBySection[indexPath.section][indexPath.row]
        if field == .exportZipArchive {
            let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
            cell.buttonText = field.localizedUIString
            cell.onTapped = { [weak self] in
                self?.exportConfigurationsAsZipFile(sourceView: cell.button)
            }
            return cell
        }
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = field.localizedUIString
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        switch settingsFieldsBySection[indexPath.section][indexPath.row] {
        case .exportZipArchive: return nil
        default: return indexPath
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let field = settingsFieldsBySection[indexPath.section][indexPath.row]
        switch field {
        case .language:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        case .viewLog:
            presentLogView()
        case .about:
            let screen = UIHostingController(rootView: AboutView())
            screen.title = tr(format: "iosAboutTitle (%@)", tr("iosAppDisplayName"))
            navigationController?.pushViewController(screen, animated: true)
        case .giteeBackup, .githubBackup, .giteeNodes:
            guard let tunnelsManager = tunnelsManager else { return }
            let screen = UIHostingController(rootView: CloudSyncView(provider: field == .githubBackup ? .github : .gitee,
                                                                     nodeSync: field == .giteeNodes, tunnels: tunnelsManager))
            screen.title = field.localizedUIString
            navigationController?.pushViewController(screen, animated: true)
        default:
            break
        }
    }
}

private struct AboutView: View {
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return tr(format: "iosAboutVersion (%@) (%@)", version, build)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text(appVersion)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)

                aboutCard("iosAboutProtocol", tr("iosAboutTrademark"))
                aboutCard("iosAboutOpenSource", tr(format: "iosAboutComponents (%@)", WIREGUARD_GO_VERSION))
                aboutCard("iosAboutUsage", tr("iosAboutUsageText"))
                aboutCard("iosAboutDisclaimer", tr("iosAboutDisclaimerText"))
                if let appLicense = bundledText("COPYING") {
                    aboutCard("iosAboutLicense", appLicense)
                }
                if let miniZipNotice = bundledText("MiniZip64_info", fileExtension: "txt") {
                    aboutCard("iosAboutMiniZipLicense", miniZipNotice)
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func bundledText(_ name: String, fileExtension: String? = nil) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func aboutCard(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr(title))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(10)
    }
}
