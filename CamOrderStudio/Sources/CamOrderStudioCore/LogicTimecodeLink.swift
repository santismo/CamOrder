import Foundation
import CoreMIDI
import Darwin

/// Dedicated transport input. Never polls host render callbacks from the UI thread.
/// Full-frame/Locate moves the stopped playhead; only running timecode or MMC Play
/// starts transport. MIDI timestamps and camera timestamps share the host clock.
public struct LogicTimecodeDecoder {
    public struct Snapshot {
        public var seconds: Double
        public var hostTime: Double
        public var playing: Bool
        public var startSeconds: Double
        public var startHostTime: Double
    }
    private var latest: Snapshot?
    private var frameDuration = 1.0 / 30.0
    private var lastQuarterTime = 0.0
    private var expectedQuarter = 0
    private var nibbles = [UInt8](repeating: 0, count: 8)
    private var cycleStart = 0.0
    private var quarterPending = false
    private var sysex: [UInt8] = []
    public private(set) var messageCount = 0
    public init() {}

    public func snapshot(now: Double) -> Snapshot? {
        guard var value = latest else { return nil }
        if value.playing {
            // Continuous MTC is its own running clock. A gap is a stop; never run
            // indefinitely on one stale packet, or reuse an old AU playing flag.
            value.playing = now - lastQuarterTime < 0.35
            value.seconds += min(max(0, now - value.hostTime), frameDuration * 2)
        }
        return value
    }
    public mutating func receive(_ bytes: [UInt8], hostTime: Double) {
        for byte in bytes {
            if byte >= 0xF8 { continue } // Real-time bytes may interrupt any message.
            if byte == 0xF0 { sysex = [byte]; quarterPending = false; continue }
            if !sysex.isEmpty {
                sysex.append(byte)
                if byte == 0xF7 { receiveSysEx(sysex, at: hostTime); sysex.removeAll(keepingCapacity: true) }
                else if sysex.count > 64 { sysex.removeAll(keepingCapacity: true) }
                continue
            }
            if byte == 0xF1 { quarterPending = true; continue }
            if quarterPending && byte < 0x80 { receiveQuarter(byte, at: hostTime) }
            quarterPending = false
        }
    }
    private mutating func receiveQuarter(_ byte: UInt8, at time: Double) {
        let part = Int(byte >> 4)
        guard part < 8 else { return }
        if part == 0 { expectedQuarter = 0; cycleStart = time }
        guard part == expectedQuarter else { expectedQuarter = 0; return }
        nibbles[part] = byte & 15
        expectedQuarter += 1
        guard part == 7 else { return }
        expectedQuarter = 0
        let hour = nibbles[6] | ((nibbles[7] & 1) << 4)
        let minute = nibbles[4] | ((nibbles[5] & 3) << 4)
        let second = nibbles[2] | ((nibbles[3] & 3) << 4)
        let frame = nibbles[0] | ((nibbles[1] & 1) << 4)
        guard let seconds = decode(hour, minute, second, frame, rate: (nibbles[7] >> 1) & 3) else { return }
        let wasPlaying = snapshot(now: time)?.playing == true
        let current = seconds + frameDuration * 2 // Complete QF messages arrive two frames late.
        let start = wasPlaying ? latest!.startSeconds : seconds
        let startHost = wasPlaying ? latest!.startHostTime : cycleStart
        latest = Snapshot(seconds: current, hostTime: time, playing: true, startSeconds: start, startHostTime: startHost)
        lastQuarterTime = time
        messageCount += 1
    }
    private mutating func receiveSysEx(_ bytes: [UInt8], at time: Double) {
        guard bytes.count >= 6, bytes[1] == 0x7F, bytes.last == 0xF7 else { return }
        if bytes[3] == 1, bytes[4] == 1, bytes.count == 10 {
            locate(Array(bytes[5...8]), at: time)
        } else if bytes[3] == 6 {
            switch bytes[4] {
            case 1: // MMC Stop; freeze at its timestamp and discard partial QF cycles.
                if var value = snapshot(now: time) { value.playing = false; value.hostTime = time; latest = value }
                expectedQuarter = 0; messageCount += 1
            case 2, 3: // Play / Deferred Play, only with a fresh known location.
                if var value = snapshot(now: time), time - value.hostTime < 0.5 {
                    value.startSeconds = value.seconds; value.startHostTime = time
                    value.hostTime = time; value.playing = true; latest = value
                    lastQuarterTime = time
                }
            case 0x44 where bytes.count == 13 && bytes[5] == 6 && bytes[6] == 1:
                locate(Array(bytes[7...10]), at: time)
            default: break // Record-arm/strobe alone must never start a take.
            }
        }
    }
    private mutating func locate(_ fields: [UInt8], at time: Double) {
        guard let seconds = decode(fields[0] & 31, fields[1], fields[2], fields[3], rate: (fields[0] >> 5) & 3) else { return }
        latest = Snapshot(seconds: seconds, hostTime: time, playing: false, startSeconds: seconds, startHostTime: time)
        expectedQuarter = 0; messageCount += 1
    }
    private mutating func decode(_ hour: UInt8, _ minute: UInt8, _ second: UInt8, _ frame: UInt8, rate: UInt8) -> Double? {
        let fps = rate == 0 ? 24 : (rate == 1 ? 25 : 30)
        guard hour < 24, minute < 60, second < 60, frame < fps else { return nil }
        frameDuration = rate == 2 ? 1001.0 / 30000.0 : 1.0 / Double(fps)
        var count = ((Int(hour) * 60 + Int(minute)) * 60 + Int(second)) * fps + Int(frame)
        if rate == 2 {
            // MTC rate 2 is SMPTE drop-frame, not simply decimal 29.97 seconds.
            let minutes = Int(hour) * 60 + Int(minute)
            count -= 2 * (minutes - minutes / 10)
        }
        return Double(count) * frameDuration
    }
}

@MainActor
public final class LogicTimecodeLink {
    public static let shared = LogicTimecodeLink(destinationName: ProcessInfo.processInfo.environment["CAMORDER_DISABLE_AUTOPREVIEW_FOR_TESTS"] == "1" ? "CamOrder Test Link " + UUID().uuidString : destinationName)
    public nonisolated static let destinationName = "CamOrder Logic Link"
    public private(set) var decoder = LogicTimecodeDecoder()
    public private(set) var error: String?
    private var client = MIDIClientRef()
    private var destination = MIDIEndpointRef()
    public init(createDestination: Bool = true, destinationName: String = LogicTimecodeLink.destinationName) {
        guard createDestination else { return }
        var status = MIDIClientCreate(destinationName as CFString, nil, nil, &client)
        if status == noErr {
            status = MIDIDestinationCreate(client, destinationName as CFString, Self.read,
                Unmanaged.passUnretained(self).toOpaque(), &destination)
        }
        if status == noErr {
            // Stable identity allows Logic to restore this destination next launch.
            if destinationName == Self.destinationName { MIDIObjectSetIntegerProperty(destination, kMIDIPropertyUniqueID, 0x436D4F72) }
        } else { error = "Could not create Logic Link (CoreMIDI \(status))." }
    }
    deinit {
        if destination != 0 { MIDIEndpointDispose(destination) }
        if client != 0 { MIDIClientDispose(client) }
    }
    public func receive(_ bytes: [UInt8], hostTime: Double) { decoder.receive(bytes, hostTime: hostTime) }
    public func snapshot(now: Double) -> LogicTimecodeDecoder.Snapshot? { decoder.snapshot(now: now) }
    nonisolated private static let read: MIDIReadProc = { packets, context, _ in
        guard let context else { return }
        let receiver = Unmanaged<LogicTimecodeLink>.fromOpaque(context).takeUnretainedValue()
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        let factor = Double(timebase.numer) / Double(timebase.denom) / 1e9
        do {
            var packet = UnsafeRawPointer(packets).advanced(by: MemoryLayout<MIDIPacketList>.offset(of: \.packet)!).assumingMemoryBound(to: MIDIPacket.self)
            for _ in 0..<packets.pointee.numPackets {
                let value = packet.pointee
                let bytes = withUnsafeBytes(of: value.data) { Array($0.prefix(Int(value.length))) }
                let timestamp = value.timeStamp == 0 ? ProcessInfo.processInfo.systemUptime : Double(value.timeStamp) * factor
                DispatchQueue.main.async { MainActor.assumeIsolated { receiver.receive(bytes, hostTime: timestamp) } }
                packet = UnsafePointer(MIDIPacketNext(packet))
            }
        }
    }
}
