// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import UIKit

class LogViewController: UIViewController, UITableViewDataSource {
    private let tableView = UITableView()
    private let busyIndicator = UIActivityIndicatorView(style: .medium)
    private var entries: [LogViewHelper.LogEntry] = []
    private var logViewHelper: LogViewHelper?
    private var isFetchingLogEntries = false
    private var clearPending = false
    private var updateLogEntriesTimer: Timer?

    private lazy var copyButton: UIBarButtonItem = {
        let button = UIBarButtonItem(image: UIImage(systemName: "doc.on.doc"), style: .plain,
                                     target: self, action: #selector(copyAllTapped))
        button.accessibilityLabel = tr("logCopyAll")
        button.isEnabled = false
        return button
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = tr("logViewTitle")
        view.backgroundColor = .systemGroupedBackground
        logViewHelper = LogViewHelper(logFilePath: FileManager.logFileURL?.path)

        let exportButton = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(saveTapped(sender:)))
        let clearButton = UIBarButtonItem(barButtonSystemItem: .trash, target: self, action: #selector(clearTapped))
        clearButton.accessibilityLabel = tr("logClear")
        clearButton.isEnabled = logViewHelper != nil
        navigationItem.rightBarButtonItems = [exportButton, clearButton, copyButton]

        tableView.backgroundColor = .systemGroupedBackground
        tableView.separatorStyle = .none
        tableView.allowsSelection = false
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 36
        tableView.dataSource = self
        tableView.register(LogEntryCell.self, forCellReuseIdentifier: "LogEntry")

        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        busyIndicator.hidesWhenStopped = true
        busyIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(busyIndicator)

        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
            busyIndicator.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            busyIndicator.centerYAnchor.constraint(equalTo: tableView.centerYAnchor)
        ])
        busyIndicator.startAnimating()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "LogEntry", for: indexPath) as! LogEntryCell
        cell.configure(with: entries[entries.count - 1 - indexPath.row], shaded: indexPath.row.isMultiple(of: 2) == false)
        return cell
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startUpdatingLogEntries()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        updateLogEntriesTimer?.invalidate()
        updateLogEntriesTimer = nil
    }

    func updateLogEntries() {
        guard let logViewHelper = logViewHelper else {
            busyIndicator.stopAnimating()
            return
        }
        guard !isFetchingLogEntries else { return }
        isFetchingLogEntries = true
        logViewHelper.fetchLogEntriesSinceLastFetch { [weak self] fetchedLogEntries in
            guard let self = self else { return }
            self.isFetchingLogEntries = false
            self.busyIndicator.stopAnimating()
            if self.clearPending {
                self.clearLog()
                return
            }
            guard !fetchedLogEntries.isEmpty else { return }
            self.append(fetchedLogEntries)
        }
    }

    private func append(_ newEntries: [LogViewHelper.LogEntry]) {
        let top = -tableView.adjustedContentInset.top
        let anchor = tableView.contentOffset.y > top + 1 ? tableView.indexPathsForVisibleRows?.first : nil
        let anchorOffset = anchor.map { tableView.rectForRow(at: $0).minY - tableView.contentOffset.y }
        entries.append(contentsOf: newEntries)
        copyButton.isEnabled = true

        UIView.performWithoutAnimation {
            tableView.reloadData()
            if let anchor = anchor, let anchorOffset = anchorOffset {
                let row = IndexPath(row: anchor.row + newEntries.count, section: anchor.section)
                tableView.scrollToRow(at: row, at: .top, animated: false)
                tableView.layoutIfNeeded()
                let y = tableView.rectForRow(at: row).minY - anchorOffset
                tableView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            } else {
                tableView.setContentOffset(CGPoint(x: 0, y: top), animated: false)
            }
        }
    }

    func startUpdatingLogEntries() {
        updateLogEntries()
        updateLogEntriesTimer?.invalidate()
        let timer = Timer(timeInterval: 1 /* second */, repeats: true) { [weak self] _ in
            self?.updateLogEntries()
        }
        updateLogEntriesTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func copyAllTapped() {
        guard !entries.isEmpty else { return }
        UIPasteboard.general.string = entries.reversed().map { $0.text() }.joined(separator: "\n")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(notification: .announcement, argument: tr("logCopied"))
    }

    @objc private func clearTapped() {
        let alert = UIAlertController(title: tr("logClear"), message: tr("logClearConfirmation"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: tr("actionCancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: tr("logClear"), style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            if self.isFetchingLogEntries {
                self.clearPending = true
            } else {
                self.clearLog()
            }
        })
        present(alert, animated: true)
    }

    private func clearLog() {
        logViewHelper?.clearLog()
        clearPending = false
        entries.removeAll()
        tableView.reloadData()
        copyButton.isEnabled = false
        updateLogEntries()
    }

    @objc func saveTapped(sender: AnyObject) {
        guard let destinationDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate, .withTime, .withTimeZone] // Avoid ':' in the filename
        let timeStampString = dateFormatter.string(from: Date())
        let destinationURL = destinationDir.appendingPathComponent("wireguard-log-\(timeStampString).txt")

        DispatchQueue.global(qos: .userInitiated).async {

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                let isDeleted = FileManager.deleteFile(at: destinationURL)
                if !isDeleted {
                    DispatchQueue.main.async {
                        ErrorPresenter.showErrorAlert(title: tr("alertUnableToRemovePreviousLogTitle"),
                                                      message: tr("alertUnableToRemovePreviousLogMessage"), from: self)
                    }
                    return
                }
            }

            let isWritten = Logger.global?.writeLog(to: destinationURL.path) ?? false

            DispatchQueue.main.async {
                guard isWritten else {
                    ErrorPresenter.showErrorAlert(title: tr("alertUnableToWriteLogTitle"), message: tr("alertUnableToWriteLogMessage"), from: self)
                    return
                }
                let activityVC = UIActivityViewController(activityItems: [destinationURL], applicationActivities: nil)
                if let sender = sender as? UIBarButtonItem {
                    activityVC.popoverPresentationController?.barButtonItem = sender
                }
                activityVC.completionWithItemsHandler = { _, _, _, _ in
                    // Remove the exported log file after the activity has completed
                    _ = FileManager.deleteFile(at: destinationURL)
                }
                self.present(activityVC, animated: true)
            }
        }
    }
}

private final class LogEntryCell: UITableViewCell {
    private let timestampLabel = UILabel()
    private let messageLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        let timestampFont = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timestampLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: timestampFont)
        timestampLabel.adjustsFontForContentSizeCategory = true
        timestampLabel.textColor = .secondaryLabel
        timestampLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timestampLabel.setContentHuggingPriority(.required, for: .horizontal)

        messageLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.numberOfLines = 0

        let row = UIStackView(arrangedSubviews: [timestampLabel, messageLabel])
        row.alignment = .top
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6)
        ])
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with entry: LogViewHelper.LogEntry, shaded: Bool) {
        // The shared log formatter uses a space between the date and HH:mm:ss.
        timestampLabel.text = entry.timestamp.split(separator: " ", maxSplits: 1).last.map { String($0.prefix(8)) }
        messageLabel.text = entry.message
        accessibilityLabel = entry.text()
        backgroundColor = shaded ? .secondarySystemBackground : .systemBackground
    }
}
