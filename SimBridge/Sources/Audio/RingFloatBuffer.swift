import Foundation

/// Pre-allocated circular float sample buffer so CoreAudio render/capture callbacks run with zero heap churn.
final class RingFloatBuffer {
    private var storage: [Float]
    let capacity: Int
    private var readIdx: Int = 0
    private var writeIdx: Int = 0
    private(set) var count: Int = 0

    init(capacity: Int = 16_384) {
        self.capacity = max(1, capacity)
        self.storage = [Float](repeating: 0, count: max(1, capacity))
    }

    func removeAll() {
        readIdx = 0
        writeIdx = 0
        count = 0
    }

    func dropOldest(_ dropCount: Int) {
        let actual = min(max(0, dropCount), count)
        guard actual > 0 else { return }
        readIdx = (readIdx + actual) % capacity
        count -= actual
        if count == 0 {
            readIdx = 0
            writeIdx = 0
        }
    }

    func push(_ src: UnsafePointer<Float>, count incoming: Int) {
        guard incoming > 0 else { return }
        var srcPtr = src
        var n = incoming
        if n > capacity {
            srcPtr = src.advanced(by: n - capacity)
            n = capacity
            readIdx = 0
            writeIdx = 0
            count = 0
        } else {
            let free = capacity - count
            if n > free {
                dropOldest(n - free)
            }
        }

        let firstChunk = min(n, capacity - writeIdx)
        storage.withUnsafeMutableBufferPointer { buf in
            guard let dstBase = buf.baseAddress else { return }
            dstBase.advanced(by: writeIdx).update(from: srcPtr, count: firstChunk)
            let rem = n - firstChunk
            if rem > 0 {
                dstBase.update(from: srcPtr.advanced(by: firstChunk), count: rem)
            }
        }
        writeIdx = (writeIdx + n) % capacity
        count += n
    }

    func pushInt16Scaled(_ src: UnsafePointer<Int16>, count incoming: Int) {
        guard incoming > 0 else { return }
        var srcPtr = src
        var n = incoming
        if n > capacity {
            srcPtr = src.advanced(by: n - capacity)
            n = capacity
            readIdx = 0
            writeIdx = 0
            count = 0
        } else {
            let free = capacity - count
            if n > free {
                dropOldest(n - free)
            }
        }

        let scale: Float = 1.0 / 32768.0
        storage.withUnsafeMutableBufferPointer { buf in
            guard let dstBase = buf.baseAddress else { return }
            let firstChunk = min(n, capacity - writeIdx)
            for i in 0..<firstChunk {
                dstBase[writeIdx + i] = Float(srcPtr[i]) * scale
            }
            let rem = n - firstChunk
            for i in 0..<rem {
                dstBase[i] = Float(srcPtr[firstChunk + i]) * scale
            }
        }
        writeIdx = (writeIdx + n) % capacity
        count += n
    }

    func pushZeros(count incoming: Int) {
        guard incoming > 0 else { return }
        if incoming >= capacity {
            storage.withUnsafeMutableBufferPointer { buf in
                buf.baseAddress?.update(repeating: 0, count: capacity)
            }
            readIdx = 0
            writeIdx = 0
            count = capacity
            return
        }
        let free = capacity - count
        if incoming > free {
            dropOldest(incoming - free)
        }
        storage.withUnsafeMutableBufferPointer { buf in
            guard let dstBase = buf.baseAddress else { return }
            let firstChunk = min(incoming, capacity - writeIdx)
            dstBase.advanced(by: writeIdx).update(repeating: 0, count: firstChunk)
            let rem = incoming - firstChunk
            if rem > 0 {
                dstBase.update(repeating: 0, count: rem)
            }
        }
        writeIdx = (writeIdx + incoming) % capacity
        count += incoming
    }

    @discardableResult
    func pop(into dst: UnsafeMutablePointer<Float>, count requested: Int) -> Int {
        let toRead = min(max(0, requested), count)
        guard toRead > 0 else { return 0 }
        storage.withUnsafeBufferPointer { buf in
            guard let srcBase = buf.baseAddress else { return }
            let firstChunk = min(toRead, capacity - readIdx)
            dst.update(from: srcBase.advanced(by: readIdx), count: firstChunk)
            let rem = toRead - firstChunk
            if rem > 0 {
                dst.advanced(by: firstChunk).update(from: srcBase, count: rem)
            }
        }
        readIdx = (readIdx + toRead) % capacity
        count -= toRead
        if count == 0 {
            readIdx = 0
            writeIdx = 0
        }
        return toRead
    }

    func popFrameAsInt16(into dst: UnsafeMutablePointer<Int16>, count requested: Int, muted: Bool) -> Bool {
        guard requested > 0, count >= requested else { return false }
        if muted {
            dst.update(repeating: 0, count: requested)
        } else {
            storage.withUnsafeBufferPointer { buf in
                guard let srcBase = buf.baseAddress else { return }
                let firstChunk = min(requested, capacity - readIdx)
                for i in 0..<firstChunk {
                    let s = max(Float(-1.0), min(Float(1.0), srcBase[readIdx + i]))
                    dst[i] = Int16(s * 32767.0)
                }
                let rem = requested - firstChunk
                for i in 0..<rem {
                    let s = max(Float(-1.0), min(Float(1.0), srcBase[i]))
                    dst[firstChunk + i] = Int16(s * 32767.0)
                }
            }
        }
        readIdx = (readIdx + requested) % capacity
        count -= requested
        if count == 0 {
            readIdx = 0
            writeIdx = 0
        }
        return true
    }
}
