import AppKit

final class DeviceCardView: NSView {
    let profileID: UUID
    var onRefresh: (() -> Void)?
    var onPowerChange: ((Bool) -> Void)?
    var onBrightnessChange: ((UInt8) -> Void)?
    var onColorChange: ((NSColor) -> Void)?
    var onDelete: (() -> Void)?

    private let nameLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "Waiting for status")
    private let powerSwitch = NSSwitch()
    private let brightnessSlider = NSSlider(value: 100, minValue: 1, maxValue: 100, target: nil, action: nil)
    private let brightnessLabel = NSTextField(labelWithString: "100%")
    private let colorWell = NSColorWell()

    init(profile: DeviceProfile) {
        profileID = profile.id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8

        nameLabel.stringValue = profile.name
        nameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        stateLabel.textColor = .secondaryLabelColor

        let refreshButton = iconButton(symbol: "arrow.clockwise", toolTip: "Refresh status", action: #selector(refreshPressed))
        let deleteButton = iconButton(symbol: "trash", toolTip: "Delete light", action: #selector(deletePressed))
        deleteButton.contentTintColor = .systemRed
        let header = NSStackView(views: [nameLabel, refreshButton, deleteButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        powerSwitch.target = self
        powerSwitch.action = #selector(powerChanged)
        let powerLabel = NSTextField(labelWithString: "Power")
        let powerRow = NSStackView(views: [powerLabel, powerSwitch])
        powerRow.orientation = .horizontal
        powerRow.alignment = .centerY
        powerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        brightnessSlider.target = self
        brightnessSlider.action = #selector(brightnessChanged)
        brightnessSlider.isContinuous = true
        brightnessLabel.alignment = .right
        brightnessLabel.translatesAutoresizingMaskIntoConstraints = false
        brightnessLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let brightnessRow = NSStackView(views: [brightnessSlider, brightnessLabel])
        brightnessRow.orientation = .horizontal
        brightnessRow.alignment = .centerY
        brightnessRow.spacing = 8

        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        colorWell.isContinuous = true
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let colorLabel = NSTextField(labelWithString: "Color")
        let colorRow = NSStackView(views: [colorLabel, colorWell])
        colorRow.orientation = .horizontal
        colorRow.alignment = .centerY
        colorLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [header, stateLabel, powerRow, brightnessRow, colorRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 250),
            heightAnchor.constraint(equalToConstant: 190),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stateLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            powerRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            brightnessRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            colorRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        setControlsEnabled(false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func showConnecting() {
        stateLabel.stringValue = "Connecting..."
        stateLabel.textColor = .secondaryLabelColor
        setControlsEnabled(false)
    }

    func showPending(_ message: String) {
        stateLabel.stringValue = message
        stateLabel.textColor = .secondaryLabelColor
    }

    func showError(_ message: String) {
        stateLabel.stringValue = message
        stateLabel.textColor = .systemRed
        setControlsEnabled(true)
    }

    func apply(_ status: AwoXLightStatus) {
        powerSwitch.state = status.isOn ? .on : .off
        let brightness = status.isColorMode ? status.colorBrightness : status.whiteBrightness
        brightnessSlider.integerValue = Int(brightness)
        brightnessLabel.stringValue = "\(brightness)%"
        colorWell.color = NSColor(
            srgbRed: CGFloat(status.red) / 255,
            green: CGFloat(status.green) / 255,
            blue: CGFloat(status.blue) / 255,
            alpha: 1
        )
        stateLabel.stringValue = status.isOnline ? (status.isOn ? "On" : "Off") : "Offline"
        stateLabel.textColor = status.isOnline ? .secondaryLabelColor : .systemOrange
        setControlsEnabled(status.isOnline)
    }

    private func setControlsEnabled(_ enabled: Bool) {
        powerSwitch.isEnabled = enabled
        brightnessSlider.isEnabled = enabled
        colorWell.isEnabled = enabled
    }

    private func iconButton(symbol: String, toolTip: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)!, target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = toolTip
        return button
    }

    @objc private func refreshPressed() {
        onRefresh?()
    }

    @objc private func deletePressed() {
        onDelete?()
    }

    @objc private func powerChanged() {
        showPending(powerSwitch.state == .on ? "Turning on..." : "Turning off...")
        onPowerChange?(powerSwitch.state == .on)
    }

    @objc private func brightnessChanged() {
        brightnessLabel.stringValue = "\(brightnessSlider.integerValue)%"
        showPending("Setting brightness...")
        onBrightnessChange?(UInt8(brightnessSlider.integerValue))
    }

    @objc private func colorChanged() {
        showPending("Setting color...")
        onColorChange?(colorWell.color)
    }
}