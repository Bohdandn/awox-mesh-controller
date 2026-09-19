import Foundation
import Network

final class MQTTClient {
    enum Status {
        case connecting
        case connected
        case subscribed
        case disconnected
        case failed(String)
    }

    var onStatus: ((Status) -> Void)?
    var onMessage: ((String, String) -> Void)?

    private let profile: MQTTIntegrationProfile
    private let queue = DispatchQueue(label: "com.github.bohdandn.awox-mesh-controller.mqtt")
    private var connection: NWConnection?
    private var buffer = Data()
    private var keepaliveTimer: DispatchSourceTimer?

    init(profile: MQTTIntegrationProfile) {
        self.profile = profile
    }

    func connect() {
        disconnect(notify: false)
        guard let port = NWEndpoint.Port(rawValue: profile.port) else {
            onStatus?(.failed("Invalid port"))
            return
        }
        let parameters = profile.usesTLS ? NWParameters.tls : NWParameters.tcp
        let connection = NWConnection(host: NWEndpoint.Host(profile.host), port: port, using: parameters)
        self.connection = connection
        onStatus?(.connecting)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, connection === self.connection else { return }
            DispatchQueue.main.async { self.handle(state) }
        }
        connection.start(queue: queue)
    }

    func disconnect() {
        disconnect(notify: true)
    }

    func publish(topic: String, payload: Data, retain: Bool = false) {
        guard !topic.isEmpty else { return }
        var body = mqttString(topic)
        body.append(payload)
        send(packet(header: retain ? 0x31 : 0x30, body: body))
    }

    func publish(topic: String, message: String, retain: Bool = false) {
        publish(topic: topic, payload: Data(message.utf8), retain: retain)
    }

    private func disconnect(notify: Bool) {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        if notify { onStatus?(.disconnected) }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            send(connectPacket())
            receive()
        case .failed(let error):
            onStatus?(.failed(error.localizedDescription))
        case .cancelled:
            onStatus?(.disconnected)
        default:
            break
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data); self.parsePackets() }
            if let error {
                DispatchQueue.main.async { self.onStatus?(.failed(error.localizedDescription)) }
            } else if complete {
                DispatchQueue.main.async { self.onStatus?(.disconnected) }
            } else {
                self.receive()
            }
        }
    }

    private func parsePackets() {
        while buffer.count >= 2 {
            var multiplier = 1
            var remaining = 0
            var index = 1
            var encoded: UInt8
            repeat {
                guard index < buffer.count, index <= 4 else { return }
                encoded = buffer[index]
                remaining += Int(encoded & 0x7f) * multiplier
                multiplier *= 128
                index += 1
            } while encoded & 0x80 != 0
            guard buffer.count >= index + remaining else { return }
            let packet = Data(buffer[index..<(index + remaining)])
            let header = buffer[0]
            buffer = Data(buffer.dropFirst(index + remaining))
            handlePacket(header: header, payload: packet)
        }
    }

    private func handlePacket(header: UInt8, payload: Data) {
        switch header >> 4 {
        case 2:
            guard payload.count >= 2, payload[1] == 0 else {
                let code = payload.count >= 2 ? payload[1] : 255
                DispatchQueue.main.async { self.onStatus?(.failed("Broker rejected connection (\(code))")) }
                return
            }
            DispatchQueue.main.async { self.onStatus?(.connected) }
            send(subscribePacket())
            startKeepalive()
        case 3:
            guard payload.count >= 2 else { return }
            let topicLength = Int(payload[0]) << 8 | Int(payload[1])
            var payloadIndex = 2 + topicLength
            guard payloadIndex <= payload.count else { return }
            let topic = String(data: payload[2..<payloadIndex], encoding: .utf8) ?? "<binary topic>"
            if header & 0x06 != 0 {
                payloadIndex += 2
                guard payloadIndex <= payload.count else { return }
            }
            let message = String(data: payload[payloadIndex...], encoding: .utf8) ?? "<binary message>"
            DispatchQueue.main.async { self.onMessage?(topic, message) }
        case 9:
            DispatchQueue.main.async { self.onStatus?(.subscribed) }
        case 13:
            break
        default:
            break
        }
    }

    private func connectPacket() -> Data {
        var flags: UInt8 = 0x02
        let hasCredentials = !profile.username.isEmpty || !profile.password.isEmpty
        if hasCredentials { flags |= 0x80 }
        if !profile.password.isEmpty { flags |= 0x40 }
        var body = mqttString("MQTT")
        body.append(0x04)
        body.append(flags)
        body.append(contentsOf: [0x00, 0x3c])
        body.append(mqttString("awox-macos-\(profile.id.uuidString.prefix(8))"))
        if hasCredentials { body.append(mqttString(profile.username)) }
        if !profile.password.isEmpty { body.append(mqttString(profile.password)) }
        return packet(header: 0x10, body: body)
    }

    private func subscribePacket() -> Data {
        var body = Data([0x00, 0x01])
        body.append(mqttString("\(profile.topic)/+/set"))
        body.append(0x00)
        return packet(header: 0x82, body: body)
    }

    private func packet(header: UInt8, body: Data) -> Data {
        var result = Data([header])
        var remaining = body.count
        repeat {
            var byte = UInt8(remaining % 128)
            remaining /= 128
            if remaining > 0 { byte |= 0x80 }
            result.append(byte)
        } while remaining > 0
        result.append(body)
        return result
    }

    private func mqttString(_ value: String) -> Data {
        let data = Data(value.utf8)
        var result = Data([UInt8(data.count >> 8), UInt8(data.count & 0xff)])
        result.append(data)
        return result
    }

    private func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.onStatus?(.failed(error.localizedDescription)) }
        })
    }

    private func startKeepalive() {
        keepaliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 45, repeating: 45)
        timer.setEventHandler { [weak self] in self?.send(Data([0xc0, 0x00])) }
        keepaliveTimer = timer
        timer.resume()
    }
}