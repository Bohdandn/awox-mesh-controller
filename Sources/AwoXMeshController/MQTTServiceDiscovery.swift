import Foundation

final class DiscoveredMQTTBroker: NSObject {
    let name: String
    let host: String
    let port: Int
    let usesTLS: Bool

    init(name: String, host: String, port: Int, usesTLS: Bool) {
        self.name = name
        self.host = host
        self.port = port
        self.usesTLS = usesTLS
    }
}

final class MQTTServiceDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var onChange: (([DiscoveredMQTTBroker]) -> Void)?

    private var browsers: [NetServiceBrowser] = []
    private var services: [NetService] = []
    private var brokers: [String: DiscoveredMQTTBroker] = [:]
    private var timeoutWorkItem: DispatchWorkItem?

    func start() {
        stop()
        for type in ["_mqtt._tcp.", "_secure-mqtt._tcp."] {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browsers.append(browser)
            browser.searchForServices(ofType: type, inDomain: "local.")
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.brokers.isEmpty else { return }
            self.onChange?([])
        }
        timeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }

    func stop() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        browsers.forEach { $0.stop() }
        services.forEach { $0.stop() }
        browsers.removeAll()
        services.removeAll()
        brokers.removeAll()
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        service.delegate = self
        services.append(service)
        service.resolve(withTimeout: 4)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostName = sender.hostName else { return }
        let host = hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
        let usesTLS = sender.type == "_secure-mqtt._tcp."
        let key = "\(host):\(sender.port):\(usesTLS)"
        brokers[key] = DiscoveredMQTTBroker(name: sender.name, host: host, port: sender.port, usesTLS: usesTLS)
        let values = brokers.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        DispatchQueue.main.async { [weak self] in self?.onChange?(values) }
    }
}