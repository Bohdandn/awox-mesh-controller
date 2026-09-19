import Foundation
import Security

struct AwoXLightStatus {
    let meshID: UInt16
    let isOnline: Bool
    let isOn: Bool
    let isColorMode: Bool
    let whiteBrightness: UInt8
    let temperature: UInt8
    let colorBrightness: UInt8
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var summary: String {
        let power = isOn ? "on" : "off"
        if isColorMode {
            return String(
                format: "Light %u is %@, RGB #%02X%02X%02X at %u%%",
                meshID, power, red, green, blue, colorBrightness
            )
        }
        return "Light \(meshID) is \(power), white level \(whiteBrightness)%, temperature \(temperature)"
    }
}

enum AwoXCrypto {
    static func makePairPacket(meshName: Data, meshPassword: Data, sessionRandom: Data) -> Data? {
        guard meshName.count <= 16, meshPassword.count <= 16, sessionRandom.count == 8 else {
            return nil
        }

        let paddedName = meshName + Data(repeating: 0, count: 16 - meshName.count)
        let paddedPassword = meshPassword + Data(repeating: 0, count: 16 - meshPassword.count)
        let combined = Data(zip(paddedName, paddedPassword).map(^))
        let randomKey = sessionRandom + Data(repeating: 0, count: 8)
        guard let encrypted = aesEncrypt(key: randomKey, block: combined) else { return nil }
        return Data([0x0c]) + sessionRandom + encrypted.prefix(8)
    }

    static func makeSessionKey(
        meshName: Data,
        meshPassword: Data,
        sessionRandom: Data,
        responseRandom: Data
    ) -> Data? {
        guard meshName.count <= 16, meshPassword.count <= 16,
              sessionRandom.count == 8, responseRandom.count == 8
        else { return nil }

        let paddedName = meshName + Data(repeating: 0, count: 16 - meshName.count)
        let paddedPassword = meshPassword + Data(repeating: 0, count: 16 - meshPassword.count)
        let combined = Data(zip(paddedName, paddedPassword).map(^))
        return aesEncrypt(key: combined, block: sessionRandom + responseRandom)
    }

    static func makeStatusRequest(sessionKey: Data, address: Data) -> Data? {
        makeCommand(
            sessionKey: sessionKey,
            address: address,
            destination: 0xffff,
            opcode: 0xda,
            parameters: Data([0x10])
        )
    }

    static func makeCommand(
        sessionKey: Data,
        address: Data,
        destination: UInt16,
        opcode: UInt8,
        parameters: Data
    ) -> Data? {
        guard sessionKey.count == 16, address.count == 6 else { return nil }
        guard parameters.count <= 10 else { return nil }
        var sequence = Data(count: 3)
        guard sequence.withUnsafeMutableBytes({
            SecRandomCopyBytes(kSecRandomDefault, 3, $0.baseAddress!)
        }) == errSecSuccess else { return nil }

        let reversedAddress = Data(address.reversed())
        let nonce = reversedAddress.prefix(4) + Data([0x01]) + sequence
        var payload = Data([
            UInt8(destination & 0xff),
            UInt8((destination >> 8) & 0xff),
            opcode,
            0x60,
            0x01,
        ])
        payload += parameters
        payload += Data(repeating: 0, count: 15 - payload.count)
        guard let checksum = makeChecksum(key: sessionKey, nonce: Data(nonce), payload: payload),
              let encryptedPayload = cryptPayload(key: sessionKey, nonce: Data(nonce), payload: payload)
        else { return nil }
        return sequence + checksum.prefix(2) + encryptedPayload
    }

    static func decryptPacket(sessionKey: Data, address: Data, packet: Data) -> Data? {
        guard sessionKey.count == 16, address.count == 6, packet.count >= 8 else { return nil }
        let reversedAddress = Data(address.reversed())
        let nonce = reversedAddress.prefix(3) + packet.prefix(5)
        let encryptedPayload = packet.dropFirst(7)
        guard let payload = cryptPayload(key: sessionKey, nonce: Data(nonce), payload: Data(encryptedPayload)),
              let checksum = makeChecksum(key: sessionKey, nonce: Data(nonce), payload: payload),
              checksum.prefix(2) == packet[5..<7]
        else { return nil }
        return packet.prefix(7) + payload
    }

    static func parseLightStatus(_ packet: Data) -> AwoXLightStatus? {
        guard packet.count == 20, packet[7] == 0xdc,
              packet[8] == 0x60, packet[9] == 0x01
        else { return nil }

        let mode = packet[12]
        return AwoXLightStatus(
            meshID: UInt16(packet[10]) | UInt16(packet[19]) << 8,
            isOnline: packet[11] > 0,
            isOn: mode & 0x01 != 0,
            isColorMode: mode & 0x02 != 0,
            whiteBrightness: packet[13],
            temperature: packet[14],
            colorBrightness: packet[15],
            red: packet[16],
            green: packet[17],
            blue: packet[18]
        )
    }

    private static func cryptPayload(key: Data, nonce: Data, payload: Data) -> Data? {
        guard nonce.count <= 15 else { return nil }
        var base = Data([0]) + nonce
        base += Data(repeating: 0, count: 16 - base.count)
        var result = Data()

        for offset in stride(from: 0, to: payload.count, by: 16) {
            guard let encryptedBase = aesEncrypt(key: key, block: base) else { return nil }
            let end = min(offset + 16, payload.count)
            result += Data(zip(encryptedBase, payload[offset..<end]).map(^))
            base[0] &+= 1
        }
        return result
    }

    private static func makeChecksum(key: Data, nonce: Data, payload: Data) -> Data? {
        var base = nonce + Data([UInt8(payload.count)])
        base += Data(repeating: 0, count: 16 - base.count)
        guard var checksum = aesEncrypt(key: key, block: base) else { return nil }

        for offset in stride(from: 0, to: payload.count, by: 16) {
            let end = min(offset + 16, payload.count)
            var block = Data(payload[offset..<end])
            block += Data(repeating: 0, count: 16 - block.count)
            checksum = Data(zip(checksum, block).map(^))
            guard let encrypted = aesEncrypt(key: key, block: checksum) else { return nil }
            checksum = encrypted
        }
        return checksum
    }

    private static func aesEncrypt(key: Data, block: Data) -> Data? {
        guard key.count == 16, block.count == 16 else { return nil }
        var reversedKey = Data(key.reversed())
        var reversedBlock = Data(block.reversed())
        var output = Data(count: 16)
        let status = reversedKey.withUnsafeMutableBytes { keyBytes in
            reversedBlock.withUnsafeMutableBytes { blockBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    awoxAES128ECBEncrypt(
                        keyBytes.bindMemory(to: UInt8.self).baseAddress!,
                        blockBytes.bindMemory(to: UInt8.self).baseAddress!,
                        outputBytes.bindMemory(to: UInt8.self).baseAddress!
                    )
                }
            }
        }
        guard status == 0 else { return nil }
        return Data(output.reversed())
    }
}

@_silgen_name("awox_aes128_ecb_encrypt")
private func awoxAES128ECBEncrypt(
    _ key: UnsafePointer<UInt8>,
    _ input: UnsafePointer<UInt8>,
    _ output: UnsafeMutablePointer<UInt8>
) -> Int32