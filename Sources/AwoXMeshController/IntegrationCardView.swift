import AppKit

final class IntegrationCardView: NSView {
    var onDelete: (() -> Void)?
    var onReconnect: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "Connecting...")
    private let messageLabel = NSTextField(wrappingLabelWithString: "No messages received")

    init(profile: MQTTIntegrationProfile) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8

        let icon = NSImageView(image: NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "MQTT")!)
        icon.contentTintColor = .systemTeal
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 32), icon.heightAnchor.constraint(equalToConstant: 32)])
        let title = NSTextField(labelWithString: profile.name)
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let type = NSTextField(labelWithString: "MQTT · \(profile.host):\(profile.port)")
        type.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [title, type])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let reconnect = iconButton(symbol: "arrow.clockwise", toolTip: "Reconnect", action: #selector(reconnectPressed))
        let delete = iconButton(symbol: "trash", toolTip: "Delete integration", action: #selector(deletePressed))
        delete.contentTintColor = .systemRed
        let header = NSStackView(views: [icon, labels, reconnect, delete])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        statusLabel.textColor = .secondaryLabelColor
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.maximumNumberOfLines = 2
        let stack = NSStackView(views: [header, statusLabel, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 250),
            heightAnchor.constraint(equalToConstant: 150),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ status: MQTTClient.Status) {
        switch status {
        case .connecting:
            statusLabel.stringValue = "Connecting..."
            statusLabel.textColor = .secondaryLabelColor
        case .connected:
            statusLabel.stringValue = "Connected, subscribing..."
            statusLabel.textColor = .systemGreen
        case .subscribed:
            statusLabel.stringValue = "Connected"
            statusLabel.textColor = .systemGreen
        case .disconnected:
            statusLabel.stringValue = "Disconnected"
            statusLabel.textColor = .secondaryLabelColor
        case .failed(let message):
            statusLabel.stringValue = "Error: \(message)"
            statusLabel.textColor = .systemRed
        }
    }

    func applyMessage(_ message: String) {
        messageLabel.stringValue = "Last message: \(message)"
        messageLabel.toolTip = message
    }

    private func iconButton(symbol: String, toolTip: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)!, target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = toolTip
        return button
    }

    @objc private func reconnectPressed() { onReconnect?() }
    @objc private func deletePressed() { onDelete?() }
}