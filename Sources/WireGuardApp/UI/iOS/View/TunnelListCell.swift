// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import UIKit

class TunnelListCell: UITableViewCell {
    var tunnel: TunnelContainer? {
        didSet {
            // Bind to the tunnel's name
            nameLabel.text = tunnel?.name ?? ""
            nameObservationToken = tunnel?.observe(\.name) { [weak self] tunnel, _ in
                self?.nameLabel.text = tunnel.name
            }
            // Bind to the tunnel's status
            update(from: tunnel, animated: false)
            statusObservationToken = tunnel?.observe(\.status) { [weak self] tunnel, _ in
                self?.update(from: tunnel, animated: true)
            }
            errorObservationToken = tunnel?.observe(\.connectionError) { [weak self] tunnel, _ in
                self?.update(from: tunnel, animated: true)
            }
            // Bind to tunnel's on-demand settings
            isOnDemandEnabledObservationToken = tunnel?.observe(\.isActivateOnDemandEnabled) { [weak self] tunnel, _ in
                self?.update(from: tunnel, animated: true)
            }
            hasOnDemandRulesObservationToken = tunnel?.observe(\.hasOnDemandRules) { [weak self] tunnel, _ in
                self?.update(from: tunnel, animated: true)
            }
        }
    }
    var onSwitchToggled: ((Bool) -> Void)?

    let nameLabel: UILabel = {
        let nameLabel = UILabel()
        nameLabel.font = UIFont.preferredFont(forTextStyle: .body)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.numberOfLines = 0
        return nameLabel
    }()

    let onDemandLabel: UILabel = {
        let label = UILabel()
        label.text = ""
        label.font = UIFont.preferredFont(forTextStyle: .caption2)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        label.textColor = .secondaryLabel
        return label
    }()

    private let statusDot: UIView = {
        let dot = UIView()
        dot.layer.cornerRadius = 7
        dot.isAccessibilityElement = false
        return dot
    }()

    private lazy var nameLeadingConstraint = nameLabel.leadingAnchor.constraint(
        equalTo: contentView.layoutMarginsGuide.leadingAnchor
    )

    let statusSwitch = UISwitch()

    private var nameObservationToken: NSKeyValueObservation?
    private var statusObservationToken: NSKeyValueObservation?
    private var errorObservationToken: NSKeyValueObservation?
    private var isOnDemandEnabledObservationToken: NSKeyValueObservation?
    private var hasOnDemandRulesObservationToken: NSKeyValueObservation?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        accessoryType = .disclosureIndicator

        for subview in [statusSwitch, statusDot, onDemandLabel, nameLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(subview)
        }

        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        onDemandLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let nameLabelBottomConstraint =
            contentView.layoutMarginsGuide.bottomAnchor.constraint(equalToSystemSpacingBelow: nameLabel.bottomAnchor, multiplier: 1)
        nameLabelBottomConstraint.priority = .defaultLow

        statusDot.isHidden = true
        NSLayoutConstraint.activate([
            statusSwitch.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            statusSwitch.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            statusSwitch.leadingAnchor.constraint(equalToSystemSpacingAfter: onDemandLabel.trailingAnchor, multiplier: 1),

            statusDot.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            statusDot.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 14),
            statusDot.heightAnchor.constraint(equalToConstant: 14),

            nameLabel.topAnchor.constraint(equalToSystemSpacingBelow: contentView.layoutMarginsGuide.topAnchor, multiplier: 1),
            nameLeadingConstraint,
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusSwitch.leadingAnchor),
            nameLabelBottomConstraint,

            onDemandLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            onDemandLabel.leadingAnchor.constraint(equalToSystemSpacingAfter: nameLabel.trailingAnchor, multiplier: 1)
        ])

        statusSwitch.addTarget(self, action: #selector(switchToggled), for: .valueChanged)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tunnel = nil
        onSwitchToggled = nil
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        statusSwitch.isEnabled = !editing
    }

    @objc private func switchToggled() {
        onSwitchToggled?(statusSwitch.isOn)
    }

    private func update(from tunnel: TunnelContainer?, animated: Bool) {
        guard let tunnel = tunnel else {
            reset(animated: animated)
            return
        }
        let status = tunnel.status
        let isOnDemandEngaged = tunnel.isActivateOnDemandEnabled
        updateStatusDot(for: tunnel)

        let shouldSwitchBeOn = ((status != .deactivating && status != .inactive) || isOnDemandEngaged)
        statusSwitch.setOn(shouldSwitchBeOn, animated: animated)

        if isOnDemandEngaged && !(status == .activating || status == .active) {
            statusSwitch.onTintColor = UIColor.systemYellow
        } else {
            statusSwitch.onTintColor = UIColor.systemGreen
        }

        statusSwitch.isUserInteractionEnabled = tunnel.hasOnDemandRules || status == .inactive || status == .active
        onDemandLabel.text = tunnel.hasOnDemandRules && isOnDemandEngaged ? tr("tunnelListCaptionOnDemand") : ""
    }

    private func updateStatusDot(for tunnel: TunnelContainer) {
        let presentation: (color: UIColor?, accessibilityText: String)
        switch tunnel.status {
        case .active:
            presentation = (.systemGreen, tr("tunnelStatusActive"))
        case .inactive:
            if let error = tunnel.connectionError {
                presentation = (.systemRed, tr(format: "tunnelListStatusFailed (%@)", error))
            } else if tunnel.isActivateOnDemandEnabled {
                presentation = (.systemOrange, tr("tunnelListStatusOnDemandWaiting"))
            } else {
                presentation = (nil, tr("tunnelStatusInactive"))
            }
        case .activating, .deactivating, .reasserting, .restarting, .waiting:
            let statusKey: String
            switch tunnel.status {
            case .activating: statusKey = "tunnelStatusActivating"
            case .deactivating: statusKey = "tunnelStatusDeactivating"
            case .reasserting: statusKey = "tunnelStatusReasserting"
            case .restarting: statusKey = "tunnelStatusRestarting"
            case .waiting: statusKey = "tunnelStatusWaiting"
            case .active, .inactive: return
            }
            presentation = (.systemOrange, tr(statusKey))
        }
        statusDot.backgroundColor = presentation.color
        statusDot.isHidden = presentation.color == nil
        nameLeadingConstraint.constant = statusDot.isHidden ? 0 : 22
        nameLabel.accessibilityValue = presentation.accessibilityText
    }

    private func reset(animated: Bool) {
        statusSwitch.thumbTintColor = nil
        statusSwitch.setOn(false, animated: animated)
        statusSwitch.isUserInteractionEnabled = false
        statusDot.backgroundColor = nil
        statusDot.isHidden = true
        nameLeadingConstraint.constant = 0
        nameLabel.accessibilityValue = nil
        onDemandLabel.text = ""
    }
}
