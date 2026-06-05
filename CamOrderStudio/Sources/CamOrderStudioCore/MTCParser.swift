import Foundation

public struct MTCParserOutput: Equatable, Sendable {
    public var timecode: Timecode
    public var state: LogicSyncState
}

public final class MTCParser: @unchecked Sendable {
    private var nibbles = Array<Int?>(repeating: nil, count: 8)
    private var lastEmitDate: Date?
    private let unstableAfterSeconds: TimeInterval

    public init(unstableAfterSeconds: TimeInterval = 2.0) {
        self.unstableAfterSeconds = unstableAfterSeconds
    }

    public func reset() {
        nibbles = Array<Int?>(repeating: nil, count: 8)
        lastEmitDate = nil
    }

    public func receive(bytes: [UInt8], receivedAt: Date = Date()) -> [MTCParserOutput] {
        var outputs: [MTCParserOutput] = []
        var index = 0
        while index < bytes.count {
            let status = bytes[index]
            if status == 0xF1, index + 1 < bytes.count {
                if let output = receiveQuarterFrame(dataByte: bytes[index + 1], receivedAt: receivedAt) {
                    outputs.append(output)
                }
                index += 2
            } else if status == 0xF0, let end = bytes[index...].firstIndex(of: 0xF7) {
                let message = Array(bytes[index...end])
                if let output = receiveFullFrame(message: message, receivedAt: receivedAt) {
                    outputs.append(output)
                }
                index = end + 1
            } else {
                index += 1
            }
        }
        return outputs
    }

    public func currentState(now: Date = Date()) -> LogicSyncState {
        guard let lastEmitDate else { return .waitingForTimecode }
        return now.timeIntervalSince(lastEmitDate) > unstableAfterSeconds ? .unstable : .chasing
    }

    private func receiveQuarterFrame(dataByte: UInt8, receivedAt: Date) -> MTCParserOutput? {
        let messageType = Int((dataByte & 0x70) >> 4)
        let value = Int(dataByte & 0x0F)
        guard (0..<8).contains(messageType) else { return nil }
        nibbles[messageType] = value

        guard messageType == 7 else { return nil }
        guard nibbles.allSatisfy({ $0 != nil }) else { return nil }
        guard let timecode = reconstructQuarterFrameTimecode() else { return nil }
        lastEmitDate = receivedAt
        return MTCParserOutput(timecode: timecode, state: .chasing)
    }

    private func reconstructQuarterFrameTimecode() -> Timecode? {
        let values = nibbles.compactMap { $0 }
        guard values.count == 8 else { return nil }
        let frames = values[0] | ((values[1] & 0x01) << 4)
        let seconds = values[2] | ((values[3] & 0x03) << 4)
        let minutes = values[4] | ((values[5] & 0x03) << 4)
        let hours = values[6] | ((values[7] & 0x01) << 4)
        let rateBits = (values[7] & 0x06) >> 1
        let frameRate = frameRate(fromMTCBits: rateBits)
        return Timecode(hours: hours, minutes: minutes, seconds: seconds, frames: frames, frameRate: frameRate)
    }

    private func receiveFullFrame(message: [UInt8], receivedAt: Date) -> MTCParserOutput? {
        // Full-frame MTC: F0 7F <device> 01 01 hr mn se fr F7.
        guard message.count >= 10, message[0] == 0xF0, message[3] == 0x01, message[4] == 0x01 else {
            return nil
        }
        let hourByte = Int(message[5])
        let rateBits = (hourByte & 0x60) >> 5
        let hours = hourByte & 0x1F
        let minutes = Int(message[6] & 0x3F)
        let seconds = Int(message[7] & 0x3F)
        let frames = Int(message[8] & 0x1F)
        let timecode = Timecode(
            hours: hours,
            minutes: minutes,
            seconds: seconds,
            frames: frames,
            frameRate: frameRate(fromMTCBits: rateBits)
        )
        lastEmitDate = receivedAt
        return MTCParserOutput(timecode: timecode, state: .locating)
    }

    private func frameRate(fromMTCBits bits: Int) -> FrameRate {
        switch bits {
        case 0: return .fps24
        case 1: return .fps25
        case 2: return .fps29_97
        default: return .fps30
        }
    }
}
