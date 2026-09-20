import AppKit
import CoreBluetooth
import Security

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, CBCentralManagerDelegate, CBPeripheralDelegate {
    private enum LightAction {
        case refresh
        case power(Bool)
        case brightness(UInt8, colorMode: Bool)
        case color(UInt8, UInt8, UInt8)
    }

    private struct PendingOperation {
        let profile: DeviceProfile
        let action: LightAction
        let savesProfile: Bool
    }

    private struct Candidate {
        let peripheral: CBPeripheral
        let deviceName: String
        let meshName: String?
        let protocolAddress: Data
        let rssi: Int
    }

    private struct MQTTLightCommand: Decodable {
        struct Color: Decodable {
            let r: Int
            let g: Int
            let b: Int
        }

        let state: String?
        let brightness: Int?
        let color: Color?
    }

    private var centralManager: CBCentralManager!
    private var mainWindow: NSWindow!
    private var cardsStack: NSStackView!
    private var emptyLabel: NSTextField!
    private var integrationsStack: NSStackView!
    private var integrationsEmptyLabel: NSTextField!
    private var addWindow: NSWindow?
    private var addDevicePopup: NSPopUpButton?
    private var addNameField: NSTextField?
    private var addMeshNameField: NSTextField?
    private var addPasswordField: NSSecureTextField?
    private var addStatusLabel: NSTextField?
    private var addSaveButton: NSButton?
    private var aboutWindow: NSWindow?
    private var logsWindow: NSWindow?
    private var logsTextView: NSTextView?
    private var settingsWindow: NSWindow?
    private var settingsIntervalLabel: NSTextField?
    private var settingsLogSizeLabel: NSTextField?
    private var integrationPickerWindow: NSWindow?
    private var mqttWindow: NSWindow?
    private var mqttNameField: NSTextField?
    private var mqttHostField: NSTextField?
    private var mqttPortField: NSTextField?
    private var mqttUsernameField: NSTextField?
    private var mqttPasswordField: NSSecureTextField?
    private var mqttTopicField: NSTextField?
    private var mqttTLSCheckbox: NSButton?
    private var mqttStatusLabel: NSTextField?
    private var mqttDiscoveryPopup: NSPopUpButton?
    private var mqttDiscovery: MQTTServiceDiscovery?
    private var statusItem: NSStatusItem?
    private var cardColumnCount = 0

    private var profiles: [DeviceProfile] = []
    private var integrationProfiles: [MQTTIntegrationProfile] = []
    private var cards: [UUID: DeviceCardView] = [:]
    private var integrationCards: [UUID: IntegrationCardView] = [:]
    private var mqttClients: [UUID: MQTTClient] = [:]
    private var integrationStatuses: [UUID: MQTTClient.Status] = [:]
    private var integrationMessages: [UUID: String] = [:]
    private var statuses: [UUID: AwoXLightStatus] = [:]
    private var candidates: [UUID: Candidate] = [:]
    private var retainedPeripherals: [UUID: CBPeripheral] = [:]
    private var operations: [PendingOperation] = []
    private var activeOperation: PendingOperation?
    private var activePeripheral: CBPeripheral?
    private var connectedProfile: DeviceProfile?
    private var pairCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var pendingServices = 0
    private var sessionRandom: Data?
    private var sessionKey: Data?
    private var pendingStatusRequest: Data?
    private var pendingControlDescription: String?
    private var pendingControlAction: LightAction?
    private var statusRequestWorkItem: DispatchWorkItem?
    private var statusRequestGeneration = 0
    private var awaitingStatus = false
    private var disconnectRequested = false
    private var operationID = 0
    private var refreshTimer: Timer?
    private var scanNeeded = false
    private var candidateSelectionWorkItem: DispatchWorkItem?
    private var candidateSelectionReady = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        profiles = DeviceStore.loadAll()
        integrationProfiles = IntegrationStore.loadAll()
        buildMenu()
        buildStatusItem()
        buildMainWindow()
        rebuildCards()
        rebuildIntegrationCards()
        connectIntegrations()
        centralManager = CBCentralManager(delegate: self, queue: .main)
        AppLogger.shared.write("Application launched with \(profiles.count) saved light(s) and \(integrationProfiles.count) integration(s)")
        AppLogger.shared.onChange = { [weak self] in self?.reloadLogsWindow() }
        configureRefreshTimer()
        NSApp.activate(ignoringOtherApps: true)
        mainWindow.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        mainWindow.makeKeyAndOrderFront(nil)
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        let aboutItem = appMenu.addItem(withTitle: "About AwoX Mesh Controller", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        let logsItem = appMenu.addItem(withTitle: "Logs", action: #selector(showLogs), keyEquivalent: "l")
        logsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit AwoX Mesh Controller", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let deviceItem = NSMenuItem()
        menu.addItem(deviceItem)
        let deviceMenu = NSMenu(title: "Device")
        let addItem = deviceMenu.addItem(withTitle: "Add Light...", action: #selector(showAddDevice), keyEquivalent: "n")
        addItem.target = self
        let refreshItem = deviceMenu.addItem(withTitle: "Refresh All", action: #selector(refreshAll), keyEquivalent: "r")
        refreshItem.target = self
        deviceItem.submenu = deviceMenu
        NSApp.mainMenu = menu
    }

    @objc private func showAbout() {
        if aboutWindow == nil { buildAboutWindow() }
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    private func buildAboutWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About AwoX Mesh Controller"
        window.isReleasedWhenClosed = false

        let icon = NSImageView(image: NSImage(named: NSImage.applicationIconName) ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "AwoX Mesh Controller")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        let commitHash = Bundle.main.object(forInfoDictionaryKey: "BuildCommitHash") as? String ?? "Unknown"
        let commitLabel = NSTextField(labelWithString: "Commit \(commitHash)")
        let buildDate = Bundle.main.object(forInfoDictionaryKey: "BuildDate") as? String ?? "Unknown"
        let buildDateLabel = NSTextField(labelWithString: "Built \(buildDate)")
        for label in [versionLabel, commitLabel, buildDateLabel] {
            label.textColor = .secondaryLabelColor
        }

        let repository = linkButton(title: "GitHub Repository", action: #selector(openRepository))
        let license = linkButton(title: "MIT License", action: #selector(openLicense))
        let links = NSStackView(views: [repository, license])
        links.orientation = .vertical
        links.alignment = .centerX
        links.spacing = 4

        let stack = NSStackView(views: [icon, title, versionLabel, commitLabel, buildDateLabel, links])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
        ])
        aboutWindow = window
        window.center()
    }

    private func linkButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .linkColor
        return button
    }

    @objc private func openRepository() {
        openExternalURL("https://github.com/Bohdandn/awox-mesh-controller")
    }

    @objc private func openLicense() {
        openExternalURL("https://github.com/Bohdandn/awox-mesh-controller/blob/main/LICENSE")
    }

    private func openExternalURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "lightbulb", accessibilityDescription: "AwoX Mesh Controller")
        item.button?.image?.isTemplate = true
        statusItem = item
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu()
        let openItem = menu.addItem(withTitle: "Open", action: #selector(showMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(.separator())
        if profiles.isEmpty {
            let emptyItem = menu.addItem(withTitle: "No lights added", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
        } else {
            for profile in profiles {
                let deviceItem = menu.addItem(withTitle: profile.name, action: #selector(toggleStatusDevice(_:)), keyEquivalent: "")
                deviceItem.target = self
                deviceItem.representedObject = profile.id
                if let status = statuses[profile.id], status.isOnline {
                    deviceItem.state = status.isOn ? .on : .off
                } else {
                    deviceItem.state = .mixed
                }
            }
        }
        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quitItem.target = NSApp
        statusItem?.menu = menu
    }

    @objc private func toggleStatusDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        enqueue(profileID: id, action: .power(!(statuses[id]?.isOn ?? false)))
    }

    private func buildMainWindow() {
        mainWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        mainWindow.title = "AwoX Mesh Controller"
        mainWindow.minSize = NSSize(width: 580, height: 380)
        mainWindow.isReleasedWhenClosed = false
        mainWindow.center()

        cardsStack = NSStackView()
        cardsStack.orientation = .vertical
        cardsStack.alignment = .leading
        cardsStack.spacing = 14
        emptyLabel = NSTextField(wrappingLabelWithString: "No lights added.")
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = .secondaryLabelColor

        integrationsStack = NSStackView()
        integrationsStack.orientation = .vertical
        integrationsStack.alignment = .leading
        integrationsStack.spacing = 14
        integrationsEmptyLabel = NSTextField(wrappingLabelWithString: "No integrations added.")
        integrationsEmptyLabel.font = .systemFont(ofSize: 15)
        integrationsEmptyLabel.textColor = .secondaryLabelColor

        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let lightsTab = NSTabViewItem(identifier: "lights")
        lightsTab.label = "Lights"
        lightsTab.view = collectionTab(title: "Lights", stack: cardsStack, addAction: #selector(showAddDevice), toolTip: "Add light")
        tabs.addTabViewItem(lightsTab)
        let integrationsTab = NSTabViewItem(identifier: "integrations")
        integrationsTab.label = "Integrations"
        integrationsTab.view = collectionTab(title: "Integrations", stack: integrationsStack, addAction: #selector(showIntegrationPicker), toolTip: "Add integration")
        tabs.addTabViewItem(integrationsTab)

        let content = NSView()
        mainWindow.contentView = content
        content.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        mainWindow.delegate = self
    }

    private func collectionTab(title: String, stack: NSStackView, addAction: Selector, toolTip: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: toolTip)!, target: self, action: addAction)
        addButton.bezelStyle = .texturedRounded
        addButton.toolTip = toolTip
        let header = NSStackView(views: [titleLabel, addButton])
        header.orientation = .horizontal
        header.alignment = .centerY

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
            document.widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
        ])
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        let content = NSStackView(views: [header, scroll])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true
        scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true
        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private var desiredCardColumnCount: Int {
        let availableWidth = max(0, (mainWindow.contentView?.bounds.width ?? 0) - 72)
        return max(1, Int((availableWidth + 14) / (250 + 14)))
    }

    private func rebuildCards() {
        cardsStack.arrangedSubviews.forEach { view in
            cardsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        cards.removeAll()
        guard !profiles.isEmpty else {
            cardsStack.addArrangedSubview(emptyLabel)
            rebuildStatusMenu()
            return
        }

        cardColumnCount = desiredCardColumnCount
        for start in stride(from: 0, to: profiles.count, by: cardColumnCount) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = 14
            for profile in profiles[start..<min(start + cardColumnCount, profiles.count)] {
                let card = makeCard(profile)
                cards[profile.id] = card
                row.addArrangedSubview(card)
            }
            while row.arrangedSubviews.count < cardColumnCount {
                row.addArrangedSubview(NSView())
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            cardsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: cardsStack.widthAnchor).isActive = true
        }
        rebuildStatusMenu()
    }

    private func makeCard(_ profile: DeviceProfile) -> DeviceCardView {
        let card = DeviceCardView(profile: profile)
        card.onRefresh = { [weak self] in self?.enqueue(profileID: profile.id, action: .refresh) }
        card.onPowerChange = { [weak self] value in self?.enqueue(profileID: profile.id, action: .power(value)) }
        card.onBrightnessChange = { [weak self] value in
            let colorMode = self?.statuses[profile.id]?.isColorMode ?? true
            self?.enqueue(profileID: profile.id, action: .brightness(value, colorMode: colorMode))
        }
        card.onColorChange = { [weak self] color in
            guard let rgb = color.usingColorSpace(.sRGB) else { return }
            let byte: (CGFloat) -> UInt8 = { UInt8(max(0, min(255, Int(($0 * 255).rounded())))) }
            self?.enqueue(profileID: profile.id, action: .color(byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent)))
        }
        card.onDelete = { [weak self] in self?.confirmDelete(profile) }
        if let status = statuses[profile.id] {
            card.apply(status)
        }
        return card
    }

    private func rebuildIntegrationCards() {
        integrationsStack.arrangedSubviews.forEach { view in
            integrationsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        integrationCards.removeAll()
        guard !integrationProfiles.isEmpty else {
            integrationsStack.addArrangedSubview(integrationsEmptyLabel)
            return
        }
        let columns = desiredCardColumnCount
        for start in stride(from: 0, to: integrationProfiles.count, by: columns) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = 14
            for profile in integrationProfiles[start..<min(start + columns, integrationProfiles.count)] {
                let card = IntegrationCardView(profile: profile)
                integrationCards[profile.id] = card
                if let status = integrationStatuses[profile.id] { card.apply(status) }
                if let message = integrationMessages[profile.id] { card.applyMessage(message) }
                card.onReconnect = { [weak self] in self?.connectIntegration(profile) }
                card.onDelete = { [weak self] in self?.confirmDeleteIntegration(profile) }
                row.addArrangedSubview(card)
            }
            while row.arrangedSubviews.count < columns { row.addArrangedSubview(NSView()) }
            row.translatesAutoresizingMaskIntoConstraints = false
            integrationsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: integrationsStack.widthAnchor).isActive = true
        }
    }

    private func connectIntegrations() {
        integrationProfiles.forEach(connectIntegration)
    }

    private func connectIntegration(_ profile: MQTTIntegrationProfile) {
        AppLogger.shared.write("\(profile.name): preparing MQTT connection to \(profile.host):\(profile.port) (TLS \(profile.usesTLS ? "enabled" : "disabled"))", level: .debug)
        mqttClients[profile.id]?.disconnect()
        let client = MQTTClient(profile: profile)
        mqttClients[profile.id] = client
        client.onStatus = { [weak self] status in
            self?.integrationStatuses[profile.id] = status
            self?.integrationCards[profile.id]?.apply(status)
            switch status {
            case .connecting:
                AppLogger.shared.write("\(profile.name): MQTT connecting")
            case .connected:
                AppLogger.shared.write("\(profile.name): MQTT connected; requesting subscription to \(profile.topic)")
            case .subscribed:
                AppLogger.shared.write("\(profile.name): MQTT subscribed to \(profile.topic)")
                self?.publishHomeAssistantDiscovery(for: profile)
                self?.publishKnownLightStates(to: profile)
            case .disconnected:
                AppLogger.shared.write("\(profile.name): MQTT disconnected", level: .warning)
            case .failed(let message):
                AppLogger.shared.write("\(profile.name): MQTT connection failed: \(message)", level: .error)
            }
        }
        client.onMessage = { [weak self] topic, message in
            let displayMessage = "\(topic): \(message)"
            self?.integrationMessages[profile.id] = displayMessage
            self?.integrationCards[profile.id]?.applyMessage(displayMessage)
            AppLogger.shared.write("\(profile.name): MQTT message received on \(topic)", level: .debug)
            self?.handleMQTTCommand(integration: profile, topic: topic, message: message)
        }
        client.connect()
    }

    private func publishHomeAssistantDiscovery(for integration: MQTTIntegrationProfile) {
        for light in profiles {
            publishHomeAssistantDiscovery(for: light, to: integration)
        }
    }

    private func publishHomeAssistantDiscovery(for light: DeviceProfile, to integration: MQTTIntegrationProfile) {
        guard let client = mqttClients[integration.id] else { return }
        let identifier = light.id.uuidString.lowercased()
        let baseTopic = "\(integration.topic)/\(identifier)"
        let configuration: [String: Any] = [
            "name": NSNull(),
            "unique_id": "awox_mesh_controller_\(identifier)",
            "schema": "json",
            "command_topic": "\(baseTopic)/set",
            "state_topic": "\(baseTopic)/state",
            "brightness": true,
            "supported_color_modes": ["rgb"],
            "device": [
                "identifiers": ["awox_mesh_controller_\(identifier)"],
                "name": light.name,
                "manufacturer": "AwoX/Telink",
                "model": "Mesh Light",
            ],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: configuration) else { return }
        client.publish(
            topic: "homeassistant/light/awox_mesh_controller/\(identifier)/config",
            payload: payload,
            retain: true
        )
        AppLogger.shared.write("\(integration.name): published Home Assistant discovery for \(light.name)", level: .debug)
    }

    private func removeHomeAssistantDiscovery(for light: DeviceProfile, from integration: MQTTIntegrationProfile) {
        guard let client = mqttClients[integration.id] else { return }
        let identifier = light.id.uuidString.lowercased()
        client.publish(topic: "homeassistant/light/awox_mesh_controller/\(identifier)/config", payload: Data(), retain: true)
        client.publish(topic: "\(integration.topic)/\(identifier)/state", payload: Data(), retain: true)
        AppLogger.shared.write("\(integration.name): removed Home Assistant discovery for \(light.name)", level: .debug)
    }

    private func publishKnownLightStates(to integration: MQTTIntegrationProfile) {
        for light in profiles {
            guard let status = statuses[light.id] else { continue }
            publishLightState(light, status: status, to: integration)
        }
    }

    private func publishLightState(_ light: DeviceProfile, status: AwoXLightStatus, to integration: MQTTIntegrationProfile) {
        let brightness = status.isColorMode ? status.colorBrightness : status.whiteBrightness
        var state: [String: Any] = [
            "state": status.isOn ? "ON" : "OFF",
            "brightness": Int((Double(brightness) * 255 / 100).rounded()),
        ]
        if status.isColorMode {
            state["color_mode"] = "rgb"
            state["color"] = ["r": status.red, "g": status.green, "b": status.blue]
        }
        guard let payload = try? JSONSerialization.data(withJSONObject: state),
              let client = mqttClients[integration.id]
        else { return }
        let identifier = light.id.uuidString.lowercased()
        client.publish(topic: "\(integration.topic)/\(identifier)/state", payload: payload, retain: true)
        AppLogger.shared.write("\(integration.name): published state for \(light.name)", level: .debug)
    }

    private func publishLightState(_ light: DeviceProfile, status: AwoXLightStatus) {
        for integration in integrationProfiles {
            publishLightState(light, status: status, to: integration)
        }
    }

    private func handleMQTTCommand(integration: MQTTIntegrationProfile, topic: String, message: String) {
        let prefix = "\(integration.topic)/"
        let suffix = "/set"
        guard topic.hasPrefix(prefix), topic.hasSuffix(suffix) else { return }
        let identifier = String(topic.dropFirst(prefix.count).dropLast(suffix.count))
        guard !identifier.contains("/"),
              let id = UUID(uuidString: identifier),
              let light = profiles.first(where: { $0.id == id })
        else {
            AppLogger.shared.write("\(integration.name): ignored command for unknown light topic \(topic)", level: .warning)
            return
        }
        guard let data = message.data(using: .utf8),
              let command = try? JSONDecoder().decode(MQTTLightCommand.self, from: data)
        else {
            AppLogger.shared.write("\(integration.name): invalid JSON command for \(light.name)", level: .warning)
            return
        }

        var actions: [LightAction] = []
        let requestedState = command.state?.uppercased()
        if requestedState == "OFF" || command.brightness == 0 {
            actions.append(.power(false))
        } else {
            let needsPowerOn = statuses[id]?.isOn != true
            if needsPowerOn && (requestedState == "ON" || command.color != nil || command.brightness != nil) {
                actions.append(.power(true))
            }
            if let color = command.color {
                let byte: (Int) -> UInt8 = { UInt8(max(0, min(255, $0))) }
                actions.append(.color(byte(color.r), byte(color.g), byte(color.b)))
            }
            if let brightness = command.brightness {
                let percent = UInt8(max(1, min(100, Int((Double(brightness) * 100 / 255).rounded()))))
                let colorMode = statuses[id]?.isColorMode ?? true
                actions.append(.brightness(percent, colorMode: colorMode))
            }
        }
        guard !actions.isEmpty else {
            AppLogger.shared.write("\(integration.name): ignored empty command for \(light.name)", level: .warning)
            return
        }
        AppLogger.shared.write("\(integration.name): accepted command for \(light.name)")
        enqueue(profileID: id, actions: actions)
    }

    private func enqueue(profileID: UUID, actions: [LightAction]) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        operations.removeAll { $0.profile.id == profileID }
        operations.append(contentsOf: actions.map { PendingOperation(profile: profile, action: $0, savesProfile: false) })
        processNextOperation()
    }

    @objc private func showIntegrationPicker() {
        if let integrationPickerWindow {
            integrationPickerWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Add Integration"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let mqtt = NSButton(title: "", target: self, action: #selector(showMQTTConfiguration))
        mqtt.bezelStyle = .regularSquare
        mqtt.setAccessibilityLabel("MQTT")
        mqtt.translatesAutoresizingMaskIntoConstraints = false
        let mqttIcon = NSImageView(image: NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "MQTT")!.withSymbolConfiguration(.init(pointSize: 58, weight: .regular))!)
        mqttIcon.contentTintColor = .systemTeal
        mqttIcon.translatesAutoresizingMaskIntoConstraints = false
        let mqttLabel = NSTextField(labelWithString: "MQTT")
        mqttLabel.font = .systemFont(ofSize: 12, weight: .medium)
        mqttLabel.translatesAutoresizingMaskIntoConstraints = false
        mqtt.addSubview(mqttIcon)
        mqtt.addSubview(mqttLabel)
        window.contentView?.addSubview(mqtt)
        NSLayoutConstraint.activate([
            mqtt.widthAnchor.constraint(equalToConstant: 190),
            mqtt.heightAnchor.constraint(equalToConstant: 140),
            mqtt.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
            mqtt.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
            mqttIcon.centerXAnchor.constraint(equalTo: mqtt.centerXAnchor),
            mqttIcon.centerYAnchor.constraint(equalTo: mqtt.centerYAnchor),
            mqttLabel.centerXAnchor.constraint(equalTo: mqtt.centerXAnchor),
            mqttLabel.bottomAnchor.constraint(equalTo: mqtt.bottomAnchor, constant: -12),
        ])
        integrationPickerWindow = window
        AppLogger.shared.write("Opened integration type picker", level: .debug)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func showMQTTConfiguration() {
        integrationPickerWindow?.close()
        integrationPickerWindow = nil
        if let mqttWindow {
            mqttWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 450),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Add MQTT Integration"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let name = NSTextField()
        name.stringValue = "MQTT"
        mqttNameField = name
        let discovered = NSPopUpButton()
        discovered.addItem(withTitle: "Searching local network...")
        discovered.isEnabled = false
        discovered.target = self
        discovered.action = #selector(mqttBrokerChanged(_:))
        mqttDiscoveryPopup = discovered
        let host = NSTextField(string: "localhost")
        mqttHostField = host
        let port = NSTextField(string: "1883")
        mqttPortField = port
        let username = NSTextField()
        username.placeholderString = "Optional"
        mqttUsernameField = username
        let password = NSSecureTextField()
        password.placeholderString = "Optional"
        mqttPasswordField = password
        let topic = NSTextField(string: "awox-mesh-controller")
        mqttTopicField = topic
        let tls = NSButton(checkboxWithTitle: "Use TLS", target: self, action: #selector(mqttTLSChanged))
        mqttTLSCheckbox = tls
        let status = NSTextField(wrappingLabelWithString: "Each light uses its own command and state topic. Home Assistant discovery is published automatically.")
        status.textColor = .secondaryLabelColor
        mqttStatusLabel = status
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeMQTTConfiguration))
        let save = NSButton(title: "Add", target: self, action: #selector(saveMQTTIntegration))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [
            formRow("Name", name), formRow("Discovered", discovered), formRow("Host", host), formRow("Port", port),
            formRow("Username", username), formRow("Password", password), formRow("Base topic", topic),
            tls, status, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        mqttWindow = window
        AppLogger.shared.write("Opened MQTT configuration", level: .debug)
        window.center()
        window.makeKeyAndOrderFront(nil)
        startMQTTDiscovery()
    }

    private func startMQTTDiscovery() {
        AppLogger.shared.write("Searching for MQTT brokers via Bonjour", level: .debug)
        let discovery = MQTTServiceDiscovery()
        mqttDiscovery = discovery
        discovery.onChange = { [weak self] brokers in
            guard let self, let popup = self.mqttDiscoveryPopup else { return }
            let selectedHost = (popup.selectedItem?.representedObject as? DiscoveredMQTTBroker)?.host
            popup.removeAllItems()
            popup.addItem(withTitle: brokers.isEmpty ? "No advertised brokers found" : "Choose a discovered broker...")
            for broker in brokers {
                popup.addItem(withTitle: "\(broker.name) · \(broker.host):\(broker.port)")
                popup.lastItem?.representedObject = broker
            }
            popup.isEnabled = !brokers.isEmpty
            if let selectedHost, let item = popup.itemArray.first(where: { ($0.representedObject as? DiscoveredMQTTBroker)?.host == selectedHost }) {
                popup.select(item)
            } else if brokers.count == 1 {
                popup.selectItem(at: 1)
                self.applyDiscoveredBroker(brokers[0])
            }
            self.mqttStatusLabel?.stringValue = brokers.isEmpty
                ? "No advertised broker found yet. You can enter one manually."
                : "Select a discovered broker or enter connection details manually."
            AppLogger.shared.write(
                brokers.isEmpty
                    ? "MQTT Bonjour discovery found no advertised brokers"
                    : "MQTT Bonjour discovery found \(brokers.count) broker(s)",
                level: brokers.isEmpty ? .warning : .info
            )
        }
        discovery.start()
    }

    @objc private func mqttBrokerChanged(_ popup: NSPopUpButton) {
        guard let broker = popup.selectedItem?.representedObject as? DiscoveredMQTTBroker else { return }
        applyDiscoveredBroker(broker)
    }

    private func applyDiscoveredBroker(_ broker: DiscoveredMQTTBroker) {
        if mqttNameField?.stringValue.isEmpty == true || mqttNameField?.stringValue == "MQTT" {
            mqttNameField?.stringValue = broker.name
        }
        mqttHostField?.stringValue = broker.host
        mqttPortField?.integerValue = broker.port
        mqttTLSCheckbox?.state = broker.usesTLS ? .on : .off
        AppLogger.shared.write("Selected discovered MQTT broker \(broker.name) at \(broker.host):\(broker.port)", level: .debug)
    }

    @objc private func mqttTLSChanged() {
        if mqttTLSCheckbox?.state == .on, mqttPortField?.stringValue == "1883" {
            mqttPortField?.stringValue = "8883"
        } else if mqttTLSCheckbox?.state == .off, mqttPortField?.stringValue == "8883" {
            mqttPortField?.stringValue = "1883"
        }
    }

    @objc private func closeMQTTConfiguration() {
        AppLogger.shared.write("Cancelled MQTT configuration", level: .debug)
        mqttDiscovery?.stop()
        mqttDiscovery = nil
        mqttWindow?.close()
        mqttWindow = nil
    }

    @objc private func saveMQTTIntegration() {
        guard let name = mqttNameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let host = mqttHostField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty,
              let portText = mqttPortField?.stringValue, let port = UInt16(portText),
              let enteredTopic = mqttTopicField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !enteredTopic.isEmpty
        else {
            mqttStatusLabel?.stringValue = "Name, host, valid port, and topic are required."
            mqttStatusLabel?.textColor = .systemRed
            return
        }
        let topic = enteredTopic.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !topic.isEmpty, !topic.contains("#"), !topic.contains("+") else {
            mqttStatusLabel?.stringValue = "Base topic cannot contain MQTT wildcards."
            mqttStatusLabel?.textColor = .systemRed
            return
        }
        let profile = MQTTIntegrationProfile(
            id: UUID(), name: name, host: host, port: port,
            username: mqttUsernameField?.stringValue ?? "",
            password: mqttPasswordField?.stringValue ?? "",
            topic: topic, usesTLS: mqttTLSCheckbox?.state == .on
        )
        AppLogger.shared.write("Saving MQTT integration \(profile.name) for \(profile.host):\(profile.port)", level: .debug)
        guard IntegrationStore.save(profile) else {
            AppLogger.shared.write("Could not save MQTT integration \(profile.name) to Keychain", level: .error)
            mqttStatusLabel?.stringValue = "Could not save integration to Keychain."
            mqttStatusLabel?.textColor = .systemRed
            return
        }
        integrationProfiles.append(profile)
        integrationProfiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        mqttDiscovery?.stop()
        mqttDiscovery = nil
        mqttWindow?.close()
        mqttWindow = nil
        rebuildIntegrationCards()
        AppLogger.shared.write("Added MQTT integration \(profile.name)")
        connectIntegration(profile)
    }

    private func confirmDeleteIntegration(_ profile: MQTTIntegrationProfile) {
        let alert = NSAlert()
        alert.messageText = "Delete \"\(profile.name)\"?"
        alert.informativeText = "The MQTT configuration and credentials will be removed from Keychain."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: mainWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn, IntegrationStore.delete(profile.id) else { return }
            guard let self else { return }
            for light in self.profiles { self.removeHomeAssistantDiscovery(for: light, from: profile) }
            let client = self.mqttClients.removeValue(forKey: profile.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { client?.disconnect() }
            self.integrationProfiles.removeAll { $0.id == profile.id }
            self.integrationStatuses.removeValue(forKey: profile.id)
            self.integrationMessages.removeValue(forKey: profile.id)
            self.rebuildIntegrationCards()
            AppLogger.shared.write("Deleted MQTT integration \(profile.name)")
        }
    }

    @objc private func showAddDevice() {
        if let addWindow {
            addWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 290),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Add Light"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        addWindow = window

        let popup = NSPopUpButton()
        popup.addItem(withTitle: "Scanning for compatible lights...")
        popup.isEnabled = false
        popup.target = self
        popup.action = #selector(addCandidateChanged)
        addDevicePopup = popup

        let nameField = NSTextField()
        nameField.placeholderString = "Living room"
        addNameField = nameField
        let meshNameField = NSTextField()
        meshNameField.placeholderString = "Mesh name"
        addMeshNameField = meshNameField
        let passwordField = NSSecureTextField()
        passwordField.placeholderString = "Mesh password"
        addPasswordField = passwordField
        let credentialHelp = NSButton(image: NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "Mesh credential help")!, target: self, action: #selector(showMeshCredentialHelp))
        credentialHelp.bezelStyle = .accessoryBarAction
        credentialHelp.isBordered = false
        credentialHelp.toolTip = "Learn where to obtain the mesh name and password"
        let passwordRow = formRow("Mesh password", passwordField)
        passwordRow.addArrangedSubview(credentialHelp)
        let status = NSTextField(wrappingLabelWithString: "Keep the light powered on while scanning.")
        status.textColor = .secondaryLabelColor
        addStatusLabel = status

        let saveButton = NSButton(title: "Add", target: self, action: #selector(addSelectedDevice))
        saveButton.keyEquivalent = "\r"
        saveButton.isEnabled = false
        addSaveButton = saveButton
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(closeAddDevice))
        let buttons = NSStackView(views: [NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [
            formRow("Bluetooth light", popup),
            formRow("Display name", nameField),
            formRow("Mesh name", meshNameField),
            passwordRow,
            status,
            buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        candidates.removeAll()
        candidateSelectionWorkItem?.cancel()
        candidateSelectionReady = false
        scanNeeded = true
        startScanning()
        window.makeKeyAndOrderFront(nil)
    }

    private func formRow(_ label: String, _ control: NSView) -> NSStackView {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.translatesAutoresizingMaskIntoConstraints = false
        labelView.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let row = NSStackView(views: [labelView, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        return row
    }

    @objc private func showMeshCredentialHelp() {
        let alert = NSAlert()
        alert.messageText = "Mesh credentials"
        alert.informativeText = "The mesh name and password are separate from your AwoX account password. The community credential tool can retrieve them from your AwoX account. Credentials are stored only in macOS Keychain."
        alert.addButton(withTitle: "Open Credential Tool")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: addWindow ?? mainWindow) { response in
            guard response == .alertFirstButtonReturn,
                  let url = URL(string: "https://fsaris.github.io/EspHome-AwoX-BLE-mesh-hub/awoxh-mesh-credentials-tool/")
            else { return }
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func addCandidateChanged() {
        guard let candidate = selectedCandidate else { return }
        applyCandidateDefaults(candidate, replacing: nil, force: true)
    }

    @objc private func addSelectedDevice() {
        guard let candidate = selectedCandidate,
              let displayName = addNameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
              let meshName = addMeshNameField?.stringValue,
              let password = addPasswordField?.stringValue,
              !displayName.isEmpty, !meshName.isEmpty, !password.isEmpty,
              Data(meshName.utf8).count <= 16, Data(password.utf8).count <= 16
        else {
            addStatusLabel?.stringValue = "Select a light and enter a display name and 1-16 byte mesh credentials."
            addStatusLabel?.textColor = .systemRed
            return
        }
        guard !profiles.contains(where: { $0.id == candidate.peripheral.identifier }) else {
            addStatusLabel?.stringValue = "This light is already saved."
            addStatusLabel?.textColor = .systemRed
            return
        }

        let profile = DeviceProfile(
            id: candidate.peripheral.identifier,
            name: displayName,
            meshName: meshName,
            meshPassword: password,
            protocolAddress: candidate.protocolAddress
        )
        addSaveButton?.isEnabled = false
        addStatusLabel?.stringValue = "Validating credentials..."
        addStatusLabel?.textColor = .secondaryLabelColor
        operations.insert(PendingOperation(profile: profile, action: .refresh, savesProfile: true), at: 0)
        scanNeeded = false
        centralManager.stopScan()
        processNextOperation()
    }

    private var selectedCandidate: Candidate? {
        guard let item = addDevicePopup?.selectedItem,
              let id = item.representedObject as? UUID
        else { return nil }
        return candidates[id]
    }

    @objc private func closeAddDevice() {
        candidateSelectionWorkItem?.cancel()
        candidateSelectionWorkItem = nil
        addWindow?.close()
        addWindow = nil
        scanNeeded = false
        if activeOperation == nil { centralManager.stopScan() }
    }

    @objc private func showLogs() {
        if logsWindow == nil { buildLogsWindow() }
        reloadLogsWindow()
        logsWindow?.makeKeyAndOrderFront(nil)
    }

    private func buildLogsWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Logs"
        window.isReleasedWhenClosed = false
        let textView = NSTextView()
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logsTextView = textView
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearLogs))
        let stack = NSStackView(views: [scroll, clear])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        logsWindow = window
    }

    private func reloadLogsWindow() {
        guard let logsTextView else { return }
        let output = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for entry in AppLogger.shared.entries() {
            let timestamp = entry.timestamp.isEmpty ? "Malformed" : entry.timestamp
            let prefix = "\(timestamp) | \(entry.level.rawValue) | "
            let color: NSColor
            switch entry.level {
            case .debug:
                color = .secondaryLabelColor
            case .info:
                color = .labelColor
            case .warning:
                color = .systemOrange
            case .error:
                color = .systemRed
            case .unknown:
                color = .systemPurple
            }
            output.append(NSAttributedString(string: prefix, attributes: [.font: font, .foregroundColor: color]))
            output.append(NSAttributedString(string: "\(entry.message)\n", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }
        logsTextView.textStorage?.setAttributedString(output)
        logsTextView.scrollToEndOfDocument(nil)
    }

    @objc private func clearLogs() {
        AppLogger.shared.clear()
    }

    @objc private func showSettings() {
        if settingsWindow == nil { buildSettingsWindow() }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func buildSettingsWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 315),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "Automatic lights refresh")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let slider = NSSlider(value: AppSettings.refreshInterval, minValue: 10, maxValue: 600, target: self, action: #selector(refreshIntervalChanged(_:)))
        slider.isContinuous = true
        let value = NSTextField(labelWithString: intervalText(AppSettings.refreshInterval))
        value.alignment = .right
        value.translatesAutoresizingMaskIntoConstraints = false
        value.widthAnchor.constraint(equalToConstant: 90).isActive = true
        settingsIntervalLabel = value
        let row = NSStackView(views: [slider, value])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        let logTitle = NSTextField(labelWithString: "Maximum logs size")
        logTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        let logSlider = NSSlider(value: Double(AppSettings.maximumLogSizeMB), minValue: 5, maxValue: 50, target: self, action: #selector(logSizeChanged(_:)))
        logSlider.isContinuous = true
        logSlider.numberOfTickMarks = 10
        logSlider.allowsTickMarkValuesOnly = true
        let logValue = NSTextField(labelWithString: "\(AppSettings.maximumLogSizeMB) MB")
        logValue.alignment = .right
        logValue.translatesAutoresizingMaskIntoConstraints = false
        logValue.widthAnchor.constraint(equalToConstant: 90).isActive = true
        settingsLogSizeLabel = logValue
        let logRow = NSStackView(views: [logSlider, logValue])
        logRow.orientation = .horizontal
        logRow.alignment = .centerY
        logRow.spacing = 12
        let levelTitle = NSTextField(labelWithString: "Log level")
        levelTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        let levelPopup = NSPopUpButton()
        for level in AppLogLevel.allCases where level != .unknown {
            levelPopup.addItem(withTitle: level.rawValue.capitalized)
            levelPopup.lastItem?.representedObject = level.rawValue
        }
        levelPopup.selectItem(withTitle: AppSettings.minimumLogLevel.rawValue.capitalized)
        levelPopup.target = self
        levelPopup.action = #selector(logLevelChanged(_:))
        levelPopup.toolTip = "Only events at this level or higher are written to the log"
        let stack = NSStackView(views: [title, row, logTitle, logRow, levelTitle, levelPopup])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            logRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        settingsWindow = window
    }

    @objc private func refreshIntervalChanged(_ slider: NSSlider) {
        let rounded = max(10, (slider.doubleValue / 10).rounded() * 10)
        slider.doubleValue = rounded
        AppSettings.refreshInterval = rounded
        settingsIntervalLabel?.stringValue = intervalText(rounded)
        configureRefreshTimer()
    }

    @objc private func logSizeChanged(_ slider: NSSlider) {
        let value = min(50, max(5, Int((slider.doubleValue / 5).rounded()) * 5))
        slider.integerValue = value
        AppSettings.maximumLogSizeMB = value
        settingsLogSizeLabel?.stringValue = "\(value) MB"
        AppLogger.shared.trimIfNeeded()
    }

    @objc private func logLevelChanged(_ popup: NSPopUpButton) {
        guard let rawValue = popup.selectedItem?.representedObject as? String,
              let level = AppLogLevel(rawValue: rawValue)
        else { return }
        AppSettings.minimumLogLevel = level
        AppLogger.shared.write("Minimum log level changed to \(level.rawValue)", level: level)
    }

    private func intervalText(_ interval: TimeInterval) -> String {
        interval >= 60 ? "\(Int(interval / 60)) min" : "\(Int(interval)) sec"
    }

    private func configureRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: AppSettings.refreshInterval, repeats: true) { [weak self] _ in
            self?.enqueueRefreshAll()
        }
    }

    @objc private func refreshAll() {
        enqueueRefreshAll()
    }

    private func enqueueRefreshAll() {
        for profile in profiles where !operations.contains(where: { $0.profile.id == profile.id }) && activeOperation?.profile.id != profile.id {
            operations.append(PendingOperation(profile: profile, action: .refresh, savesProfile: false))
        }
        processNextOperation()
    }

    private func isContinuousControl(_ action: LightAction) -> Bool {
        switch action {
        case .brightness(_, _), .color(_, _, _):
            return true
        case .refresh, .power(_):
            return false
        }
    }

    private func cancelStatusRequest() {
        statusRequestWorkItem?.cancel()
        statusRequestWorkItem = nil
        statusRequestGeneration += 1
    }

    private func resetOperationState() {
        pendingStatusRequest = nil
        pendingControlDescription = nil
        pendingControlAction = nil
        cancelStatusRequest()
        awaitingStatus = false
    }

    private func canReuseConnection(for profile: DeviceProfile) -> Bool {
        guard connectedProfile?.id == profile.id,
              let peripheral = activePeripheral,
              peripheral.state == .connected,
              sessionKey != nil,
              pairCharacteristic != nil,
              statusCharacteristic != nil,
              commandCharacteristic != nil
        else { return false }
        return true
    }

    private func enqueue(profileID: UUID, action: LightAction) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }

        if isContinuousControl(action), let active = activeOperation, active.profile.id == profileID {
            let replacement = PendingOperation(profile: profile, action: action, savesProfile: active.savesProfile)
            if sessionKey == nil || activePeripheral == nil {
                activeOperation = replacement
                return
            }
            if pendingControlDescription != nil || awaitingStatus {
                pendingControlAction = action
                return
            }
            cancelStatusRequest()
            activeOperation = replacement
            performActiveAction()
            return
        }

        operations.removeAll { $0.profile.id == profileID }
        operations.append(PendingOperation(profile: profile, action: action, savesProfile: false))
        processNextOperation()
    }

    private func processNextOperation() {
        guard activeOperation == nil, !operations.isEmpty else { return }

        let operation = operations[0]
        if canReuseConnection(for: operation.profile) {
            operations.removeFirst()
            beginOperation(operation, reusingConnection: true)
            return
        }

        if let peripheral = activePeripheral, peripheral.state != .disconnected {
            guard !disconnectRequested else { return }
            disconnectRequested = true
            if peripheral.state != .disconnecting {
                centralManager.cancelPeripheralConnection(peripheral)
            }
            return
        }

        if activePeripheral != nil || connectedProfile != nil || sessionKey != nil {
            resetConnectionState()
        }
        operations.removeFirst()
        beginOperation(operation, reusingConnection: false)
    }

    private func beginOperation(_ operation: PendingOperation, reusingConnection: Bool) {
        activeOperation = operation
        operationID += 1
        resetOperationState()
        if reusingConnection {
            let message = isContinuousControl(operation.action) ? "Sending..." : "Refreshing..."
            cards[operation.profile.id]?.showPending(message)
            performActiveAction()
            return
        }
        if isContinuousControl(operation.action) {
            cards[operation.profile.id]?.showPending("Connecting...")
        } else {
            cards[operation.profile.id]?.showConnecting()
        }
        AppLogger.shared.write("Connecting to \(operation.profile.name)")

        let id = operation.profile.id
        if let peripheral = retainedPeripherals[id] ?? centralManager.retrievePeripherals(withIdentifiers: [id]).first {
            retainedPeripherals[id] = peripheral
            activePeripheral = peripheral
            peripheral.delegate = self
            centralManager.connect(peripheral)
        } else {
            scanNeeded = true
            startScanning()
        }
    }

    private func startScanning() {
        guard centralManager?.state == .poweredOn else { return }
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        AppLogger.shared.write("Bluetooth state changed to \(central.state.rawValue)", level: .debug)
        guard central.state == .poweredOn else { return }
        if addWindow != nil || activeOperation != nil { startScanning() }
        enqueueRefreshAll()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              manufacturerData.count >= 8
        else { return }
        let previous = candidates[peripheral.identifier]
        let localName = normalizedName(advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        let peripheralName = normalizedName(peripheral.name)
        let meshName = preferredMeshName(localName: localName, peripheralName: peripheralName, previous: previous)
        let deviceName = preferredDeviceName(localName: localName, peripheralName: peripheralName, meshName: meshName, previous: previous)
        let address = Data([0, 0]) + Data(manufacturerData[4..<8].reversed())
        let candidate = Candidate(
            peripheral: peripheral,
            deviceName: deviceName,
            meshName: meshName,
            protocolAddress: address,
            rssi: RSSI.intValue
        )
        candidates[peripheral.identifier] = candidate
        retainedPeripherals[peripheral.identifier] = peripheral

        if addWindow != nil, !profiles.contains(where: { $0.id == peripheral.identifier }) {
            upsertCandidateInPopup(candidate, replacing: previous)
        }
        if activeOperation?.profile.id == peripheral.identifier, activePeripheral == nil {
            scanNeeded = false
            central.stopScan()
            activePeripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral)
        }
    }

    private func upsertCandidateInPopup(_ candidate: Candidate, replacing previous: Candidate?) {
        guard let popup = addDevicePopup else { return }
        let selectedID = popup.selectedItem?.representedObject as? UUID
        let available = candidates.values
            .filter { candidate in !profiles.contains(where: { $0.id == candidate.peripheral.identifier }) }
            .sorted { left, right in
                let leftNamed = left.deviceName != "Unknown device"
                let rightNamed = right.deviceName != "Unknown device"
                if leftNamed != rightNamed { return leftNamed }
                let nameOrder = left.deviceName.localizedCaseInsensitiveCompare(right.deviceName)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return left.rssi > right.rssi
            }
        popup.removeAllItems()
        if !candidateSelectionReady {
            popup.addItem(withTitle: "Scanning for named lights...")
        }
        for value in available {
            let shortIdentifier = String(value.peripheral.identifier.uuidString.prefix(8))
            popup.addItem(withTitle: "\(value.deviceName)  ·  \(shortIdentifier)  ·  \(value.rssi) dBm")
            popup.lastItem?.representedObject = value.peripheral.identifier
        }
        if !candidateSelectionReady {
            popup.selectItem(at: 0)
            popup.isEnabled = false
            addSaveButton?.isEnabled = false
            if candidateSelectionWorkItem == nil {
                let item = DispatchWorkItem { [weak self] in
                    guard let self, self.addWindow != nil else { return }
                    self.candidateSelectionWorkItem = nil
                    self.candidateSelectionReady = true
                    guard let best = self.candidates.values.sorted(by: { left, right in
                        let leftNamed = left.deviceName != "Unknown device"
                        let rightNamed = right.deviceName != "Unknown device"
                        if leftNamed != rightNamed { return leftNamed }
                        return left.rssi > right.rssi
                    }).first else { return }
                    self.upsertCandidateInPopup(best, replacing: nil)
                }
                candidateSelectionWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
            }
            return
        }
        if let selectedID, let selectedItem = popup.itemArray.first(where: { ($0.representedObject as? UUID) == selectedID }) {
            popup.select(selectedItem)
        } else if !available.isEmpty {
            popup.selectItem(at: 0)
        }
        popup.isEnabled = true
        addSaveButton?.isEnabled = true
        if selectedID == nil {
            addCandidateChanged()
        } else if selectedID == candidate.peripheral.identifier {
            applyCandidateDefaults(candidate, replacing: previous, force: false)
        }
        addStatusLabel?.stringValue = "Select a light and enter its mesh credentials."
    }

    private func normalizedName(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private func preferredMeshName(
        localName: String?,
        peripheralName: String?,
        previous: Candidate?
    ) -> String? {
        if let localName, localName.count == 8 { return localName }
        if let peripheralName, peripheralName.count == 8, peripheralName != localName { return peripheralName }
        if let previous = previous?.meshName { return previous }
        if let localName, localName != peripheralName { return localName }
        return nil
    }

    private func preferredDeviceName(
        localName: String?,
        peripheralName: String?,
        meshName: String?,
        previous: Candidate?
    ) -> String {
        if let peripheralName, peripheralName != meshName { return peripheralName }
        if let previous, previous.deviceName != previous.meshName { return previous.deviceName }
        if let localName, localName != meshName { return localName }
        return peripheralName ?? localName ?? "Unknown device"
    }

    private func applyCandidateDefaults(_ candidate: Candidate, replacing previous: Candidate?, force: Bool) {
        if force || addNameField?.stringValue.isEmpty == true || addNameField?.stringValue == previous?.deviceName {
            addNameField?.stringValue = candidate.deviceName
        }
        if force || addMeshNameField?.stringValue.isEmpty == true || addMeshNameField?.stringValue == previous?.meshName {
            addMeshNameField?.stringValue = candidate.meshName ?? ""
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let operation = activeOperation, operation.profile.id == peripheral.identifier else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        connectedProfile = operation.profile
        disconnectRequested = false
        AppLogger.shared.write("Connected to \(operation.profile.name)")
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        failActive("Connection failed")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard activePeripheral?.identifier == peripheral.identifier else { return }
        let wasRequested = disconnectRequested
        let disconnectedProfile = connectedProfile ?? activeOperation?.profile
        resetConnectionState()
        if !wasRequested, activeOperation != nil {
            failActive("Disconnected")
            return
        }
        if !wasRequested,
           let disconnectedProfile,
           profiles.contains(where: { $0.id == disconnectedProfile.id }),
           !operations.contains(where: { $0.profile.id == disconnectedProfile.id }) {
            operations.insert(PendingOperation(profile: disconnectedProfile, action: .refresh, savesProfile: false), at: 0)
        }
        processNextOperation()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services, !services.isEmpty else {
            failActive("Service discovery failed")
            return
        }
        pendingServices = services.count
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            let uuid = characteristic.uuid.uuidString.uppercased()
            if uuid.hasSuffix("0D1911") {
                statusCharacteristic = characteristic
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else if uuid.hasSuffix("0D1912") {
                commandCharacteristic = characteristic
            } else if uuid.hasSuffix("0D1914") {
                pairCharacteristic = characteristic
            }
        }
        pendingServices -= 1
        if pendingServices == 0 {
            guard pairCharacteristic != nil, statusCharacteristic != nil, commandCharacteristic != nil else {
                failActive("Not a compatible Telink mesh light")
                return
            }
            authenticateActive()
        }
    }

    private func authenticateActive() {
        guard let operation = activeOperation, let peripheral = activePeripheral, let pairCharacteristic else { return }
        var random = Data(count: 8)
        guard random.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }) == errSecSuccess,
              let packet = AwoXCrypto.makePairPacket(
                  meshName: Data(operation.profile.meshName.utf8),
                  meshPassword: Data(operation.profile.meshPassword.utf8),
                  sessionRandom: random
              )
        else {
            failActive("Could not create authentication request")
            return
        }
        sessionRandom = random
        peripheral.writeValue(packet, for: pairCharacteristic, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if error != nil {
            failActive("Bluetooth write failed")
            return
        }
        if characteristic.uuid == pairCharacteristic?.uuid {
            peripheral.readValue(for: characteristic)
        } else if characteristic.uuid == statusCharacteristic?.uuid {
            guard let request = pendingStatusRequest, let commandCharacteristic else {
                failActive("Status request setup failed")
                return
            }
            pendingStatusRequest = nil
            peripheral.writeValue(request, for: commandCharacteristic, type: .withResponse)
        } else if characteristic.uuid == commandCharacteristic?.uuid, pendingControlDescription != nil {
            pendingControlDescription = nil
            if let nextAction = pendingControlAction {
                pendingControlAction = nil
                guard let operation = activeOperation else { return }
                activeOperation = PendingOperation(profile: operation.profile, action: nextAction, savesProfile: operation.savesProfile)
                performActiveAction()
            } else {
                scheduleStatusRequest()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let error, characteristic.uuid != statusCharacteristic?.uuid else { return }
        AppLogger.shared.write("Notification subscription warning: \(error.localizedDescription)", level: .warning)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == pairCharacteristic?.uuid {
            handleAuthenticationResponse(characteristic.value)
        } else if characteristic.uuid == statusCharacteristic?.uuid {
            handleStatusPacket(characteristic.value)
        }
    }

    private func handleAuthenticationResponse(_ response: Data?) {
        guard let operation = activeOperation, let response, response.count >= 9, response[0] == 0x0d,
              let sessionRandom,
              let key = AwoXCrypto.makeSessionKey(
                  meshName: Data(operation.profile.meshName.utf8),
                  meshPassword: Data(operation.profile.meshPassword.utf8),
                  sessionRandom: sessionRandom,
                  responseRandom: response[1..<9]
              )
        else {
            failActive("Authentication failed")
            return
        }
        sessionKey = key
        self.sessionRandom = nil
        if operation.savesProfile {
            guard DeviceStore.save(operation.profile) else {
                failActive("Could not save light to Keychain")
                return
            }
            profiles.append(operation.profile)
            profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            rebuildCards()
            for integration in integrationProfiles {
                publishHomeAssistantDiscovery(for: operation.profile, to: integration)
            }
            addPasswordField?.stringValue = ""
            addWindow?.close()
            addWindow = nil
            AppLogger.shared.write("Added light \(operation.profile.name)")
        }
        performActiveAction()
    }

    private func performActiveAction() {
        guard let operation = activeOperation, let key = sessionKey, let peripheral = activePeripheral,
              let commandCharacteristic else { return }
        switch operation.action {
        case .refresh:
            requestStatus()
        case .power(let on):
            sendControl(
                AwoXCrypto.makeCommand(sessionKey: key, address: operation.profile.protocolAddress, destination: statusDestination, opcode: 0xd0, parameters: Data([on ? 1 : 0, 0, 0])),
                description: on ? "Power on" : "Power off",
                peripheral: peripheral,
                characteristic: commandCharacteristic
            )
        case .brightness(let value, let colorMode):
            sendControl(
                AwoXCrypto.makeCommand(sessionKey: key, address: operation.profile.protocolAddress, destination: statusDestination, opcode: colorMode ? 0xf2 : 0xf1, parameters: Data([value])),
                description: "Brightness \(value)%",
                peripheral: peripheral,
                characteristic: commandCharacteristic
            )
        case .color(let red, let green, let blue):
            sendControl(
                AwoXCrypto.makeCommand(sessionKey: key, address: operation.profile.protocolAddress, destination: statusDestination, opcode: 0xe2, parameters: Data([0x04, red, green, blue])),
                description: String(format: "Color #%02X%02X%02X", red, green, blue),
                peripheral: peripheral,
                characteristic: commandCharacteristic
            )
        }
    }

    private var statusDestination: UInt16 {
        activeOperation.flatMap { statuses[$0.profile.id]?.meshID } ?? 0xffff
    }

    private func sendControl(_ packet: Data?, description: String, peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard let packet else {
            failActive("Could not create command")
            return
        }
        pendingControlDescription = description
        cards[activeOperation!.profile.id]?.showPending(description)
        AppLogger.shared.write("Sending \(description) to \(activeOperation!.profile.name)")
        peripheral.writeValue(packet, for: characteristic, type: .withResponse)
    }

    private func requestStatus() {
        guard let operation = activeOperation, let key = sessionKey, let peripheral = activePeripheral,
              let statusCharacteristic,
              let request = AwoXCrypto.makeStatusRequest(sessionKey: key, address: operation.profile.protocolAddress)
        else {
            failActive("Could not create status request")
            return
        }
        pendingStatusRequest = request
        awaitingStatus = true
        let id = operationID
        peripheral.writeValue(Data([0x01]), for: statusCharacteristic, type: .withResponse)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.awaitingStatus, self.operationID == id else { return }
            self.failActive("Status refresh timed out")
        }
    }

    private func scheduleStatusRequest() {
        statusRequestWorkItem?.cancel()
        statusRequestGeneration += 1
        let generation = statusRequestGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.statusRequestGeneration == generation else { return }
            self.statusRequestWorkItem = nil
            self.requestStatus()
        }
        statusRequestWorkItem = item
        let delay: TimeInterval
        if let action = activeOperation?.action, case .power(true) = action {
            delay = 1.0
        } else {
            delay = 0.3
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func shouldHandleStatusPacket(for operation: PendingOperation) -> Bool {
        guard !awaitingStatus else { return true }
        if case .power(true) = operation.action {
            return false
        }
        return true
    }

    private func handleStatusPacket(_ packet: Data?) {
        guard let operation = activeOperation,
              shouldHandleStatusPacket(for: operation),
              let key = sessionKey, let packet,
              let plaintext = AwoXCrypto.decryptPacket(sessionKey: key, address: operation.profile.protocolAddress, packet: packet),
              let status = AwoXCrypto.parseLightStatus(plaintext)
        else { return }
        awaitingStatus = false
        statuses[operation.profile.id] = status
        rebuildStatusMenu()
        publishLightState(operation.profile, status: status)
        AppLogger.shared.write("\(operation.profile.name): \(status.summary)")
        if let nextAction = pendingControlAction {
            pendingControlAction = nil
            activeOperation = PendingOperation(profile: operation.profile, action: nextAction, savesProfile: operation.savesProfile)
            performActiveAction()
        } else {
            cards[operation.profile.id]?.apply(status)
            finishActive()
        }
    }

    private func disconnectCurrentConnection() {
        guard let peripheral = activePeripheral else {
            resetConnectionState()
            processNextOperation()
            return
        }
        guard peripheral.state != .disconnected else {
            resetConnectionState()
            processNextOperation()
            return
        }
        disconnectRequested = true
        if peripheral.state != .disconnecting {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    private func finishActive(preserveConnection: Bool = true) {
        activeOperation = nil
        resetOperationState()
        if preserveConnection, activePeripheral?.state == .connected, sessionKey != nil {
            processNextOperation()
        } else {
            disconnectCurrentConnection()
        }
    }

    private func failActive(_ message: String) {
        guard let operation = activeOperation else { return }
        AppLogger.shared.write("\(operation.profile.name): \(message)", level: .error)
        cards[operation.profile.id]?.showError(message)
        if operation.savesProfile {
            _ = DeviceStore.delete(operation.profile.id)
            profiles.removeAll { $0.id == operation.profile.id }
            rebuildCards()
            addStatusLabel?.stringValue = message
            addStatusLabel?.textColor = .systemRed
            addSaveButton?.isEnabled = true
        }
        finishActive(preserveConnection: false)
    }

    private func resetConnectionState() {
        resetOperationState()
        activePeripheral = nil
        connectedProfile = nil
        pairCharacteristic = nil
        statusCharacteristic = nil
        commandCharacteristic = nil
        pendingServices = 0
        sessionRandom = nil
        sessionKey = nil
        disconnectRequested = false
    }

    private func confirmDelete(_ profile: DeviceProfile) {
        let alert = NSAlert()
        alert.messageText = "Delete \"\(profile.name)\"?"
        alert.informativeText = "The saved light and its mesh credentials will be removed from Keychain."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: mainWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn, DeviceStore.delete(profile.id) else { return }
            guard let self else { return }
            for integration in self.integrationProfiles {
                self.removeHomeAssistantDiscovery(for: profile, from: integration)
            }
            self.operations.removeAll { $0.profile.id == profile.id }
            self.profiles.removeAll { $0.id == profile.id }
            self.statuses.removeValue(forKey: profile.id)
            self.rebuildCards()
            AppLogger.shared.write("Deleted light \(profile.name)")
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowDidResize(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindow,
              desiredCardColumnCount != cardColumnCount
        else { return }
        rebuildCards()
        rebuildIntegrationCards()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window == addWindow {
            addWindow = nil
            scanNeeded = false
            if activeOperation == nil { centralManager.stopScan() }
        } else if window == integrationPickerWindow {
            integrationPickerWindow = nil
        } else if window == mqttWindow {
            mqttDiscovery?.stop()
            mqttDiscovery = nil
            mqttWindow = nil
        }
    }
}
