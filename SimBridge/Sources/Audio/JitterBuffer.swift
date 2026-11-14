import Foundation

final class JitterBuffer {
    enum PopResult {
        case frame(payload: Data, useFec: Bool)
        case missingPlc
        case underrunSilence
    }

    struct Stats: Equatable, Sendable {
        var receivedFrames: Int64 = 0
        var plcFrames: Int64 = 0
        var lateDropFrames: Int64 = 0
        var overflowDropFrames: Int64 = 0
        var queuedFrames: Int = 0
    }

    private let lock = NSLock()
    private let targetDepthFrames: Int
    private let maxDepthFrames: Int
    private var buffer: [UInt16: Data] = [:]
    private var started = false
    private var nextSeq: UInt16 = 0
    private var consecutiveMisses = 0

    private(set) var receivedCount: Int64 = 0
    private(set) var plcCount: Int64 = 0
    private(set) var lateDropCount: Int64 = 0
    private(set) var overflowDropCount: Int64 = 0

    init(targetDepthFrames: Int = 3, maxDepthFrames: Int = 10) {
        self.targetDepthFrames = targetDepthFrames
        self.maxDepthFrames = maxDepthFrames
    }

    func statsSnapshot() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return Stats(
            receivedFrames: receivedCount,
            plcFrames: plcCount,
            lateDropFrames: lateDropCount,
            overflowDropFrames: overflowDropCount,
            queuedFrames: buffer.count
        )
    }

    func push(seq: UInt16, payload: Data) {
        lock.lock()
        defer { lock.unlock() }
        receivedCount += 1

        if !started {
            if buffer.isEmpty {
                nextSeq = seq
            } else if Self.seqDiff(seq, nextSeq) < 0 {
                nextSeq = seq
            }
            buffer[seq] = payload
            if buffer.count >= targetDepthFrames {
                started = true
            }
            return
        }

        let delta = Self.seqDiff(seq, nextSeq)
        if delta < 0 {
            if delta < -250 {
                buffer.removeAll(keepingCapacity: true)
                buffer[seq] = payload
                nextSeq = seq
                started = false
                consecutiveMisses = 0
                return
            }
            lateDropCount += 1
            return
        }

        if delta >= maxDepthFrames * 4 {
            buffer.removeAll(keepingCapacity: true)
            buffer[seq] = payload
            nextSeq = seq
            started = false
            consecutiveMisses = 0
            return
        }

        buffer[seq] = payload
        while buffer.count > maxDepthFrames {
            guard let oldest = findOldestKey() else { break }
            buffer.removeValue(forKey: oldest)
            if Self.seqDiff(oldest, nextSeq) >= 0 {
                nextSeq = oldest &+ 1
            }
            overflowDropCount += 1
        }
    }

    func pop() -> PopResult {
        lock.lock()
        defer { lock.unlock() }

        guard started else { return .underrunSilence }

        if let exact = buffer.removeValue(forKey: nextSeq) {
            nextSeq = nextSeq &+ 1
            consecutiveMisses = 0
            return .frame(payload: exact, useFec: false)
        }

        if let nextPlusOne = buffer[nextSeq &+ 1] {
            nextSeq = nextSeq &+ 1
            consecutiveMisses = 0
            plcCount += 1
            return .frame(payload: nextPlusOne, useFec: true)
        }

        consecutiveMisses += 1
        if buffer.isEmpty && consecutiveMisses >= 10 {
            started = false
            consecutiveMisses = 0
            return .underrunSilence
        }

        nextSeq = nextSeq &+ 1
        plcCount += 1
        return .missingPlc
    }

    func trimToTarget() {
        lock.lock()
        defer { lock.unlock() }
        while buffer.count > targetDepthFrames {
            guard let oldest = findOldestKey() else { break }
            buffer.removeValue(forKey: oldest)
            if Self.seqDiff(oldest, nextSeq) >= 0 {
                nextSeq = oldest &+ 1
            }
        }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: true)
        started = false
        nextSeq = 0
        consecutiveMisses = 0
    }

    func resetAllStats() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: true)
        started = false
        nextSeq = 0
        consecutiveMisses = 0
        receivedCount = 0
        plcCount = 0
        lateDropCount = 0
        overflowDropCount = 0
    }

    private func findOldestKey() -> UInt16? {
        var oldest: UInt16?
        var minDelta = Int.max
        for k in buffer.keys {
            let d = Self.seqDiff(k, nextSeq)
            if d < minDelta {
                minDelta = d
                oldest = k
            }
        }
        return oldest
    }

    static func seqDiff(_ a: UInt16, _ b: UInt16) -> Int {
        let d = Int(a &- b)
        return d >= 0x8000 ? d - 0x10000 : d
    }
}
