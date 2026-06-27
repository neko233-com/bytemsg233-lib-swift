import Foundation

public enum ByteMsgWireType: UInt8 {
    case varint = 0
    case fixed64 = 1
    case bytes = 2
    case fixed32 = 5
}

public protocol ByteMsgResettable {
    func reset()
}

public final class ByteMsgPool<T: ByteMsgResettable> {
    private let factory: () -> T
    private var items: [T] = []

    public init(factory: @escaping () -> T) {
        self.factory = factory
    }

    public func rent() -> T {
        if let item = items.popLast() { return item }
        return factory()
    }

    public func `return`(_ value: T) {
        value.reset()
        items.append(value)
    }
}

public func zigzagEncode(_ value: Int64) -> UInt64 {
    return (UInt64(value) << 1) ^ (UInt64(bitPattern: value >> 63))
}

public func zigzagDecode(_ value: UInt64) -> Int64 {
    return Int64(bitPattern: (value >> 1) ^ -(value & 1))
}

public final class ByteMsgWriter {
    private var buf: [UInt8]
    private var pos: Int = 0

    public init(capacity: Int = 256) {
        buf = [UInt8](repeating: 0, count: capacity)
    }

    public func finish() -> [UInt8] {
        return Array(buf[..<pos])
    }

    public func reset() {
        pos = 0
    }

    private func ensure(_ additional: Int) {
        if pos + additional > buf.count {
            var newBuf = [UInt8](repeating: 0, count: max(buf.count * 2, pos + additional))
            for i in 0..<pos { newBuf[i] = buf[i] }
            buf = newBuf
        }
    }

    public func writeVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            ensure(1)
            buf[pos] = UInt8(v & 0x7F) | 0x80
            pos += 1
            v >>= 7
        }
        ensure(1)
        buf[pos] = UInt8(v)
        pos += 1
    }

    public func writeHeader(_ tag: UInt32, wireType: ByteMsgWireType) {
        writeVarint((UInt64(tag) << 3) | UInt64(wireType.rawValue))
    }

    public func writeFixed32(_ value: UInt32) {
        ensure(4)
        buf[pos] = UInt8(value & 0xFF)
        buf[pos + 1] = UInt8((value >> 8) & 0xFF)
        buf[pos + 2] = UInt8((value >> 16) & 0xFF)
        buf[pos + 3] = UInt8((value >> 24) & 0xFF)
        pos += 4
    }

    public func writeFixed64(_ value: UInt64) {
        ensure(8)
        for i in 0..<8 {
            buf[pos + i] = UInt8((value >> (i * 8)) & 0xFF)
        }
        pos += 8
    }

    public func writeStringValue(_ value: String) {
        let bytes = Array(value.utf8)
        writeVarint(UInt64(bytes.count))
        ensure(bytes.count)
        for b in bytes { buf[pos] = b; pos += 1 }
    }

    public func writeString(_ tag: UInt32, _ value: String) {
        writeHeader(tag, wireType: .bytes)
        writeStringValue(value)
    }

    public func writeUintField(_ tag: UInt32, _ value: UInt64) {
        writeHeader(tag, wireType: .varint)
        writeVarint(value)
    }

    public func writeInt32Field(_ tag: UInt32, _ value: Int32) {
        writeHeader(tag, wireType: .varint)
        writeVarint(UInt64(bitPattern: Int64(value)))
    }

    public func writeInt64Field(_ tag: UInt32, _ value: Int64) {
        writeHeader(tag, wireType: .varint)
        writeVarint(zigzagEncode(value))
    }

    public func writeFloatField(_ tag: UInt32, _ value: Float) {
        writeHeader(tag, wireType: .fixed32)
        var bits = value.bitPattern
        writeFixed32(bits)
    }

    public func writeDoubleField(_ tag: UInt32, _ value: Double) {
        writeHeader(tag, wireType: .fixed64)
        var bits = value.bitPattern
        writeFixed64(bits)
    }

    public func writeBoolField(_ tag: UInt32, _ value: Bool) {
        writeHeader(tag, wireType: .varint)
        writeVarint(value ? 1 : 0)
    }

    public func writeEnumField(_ tag: UInt32, _ value: Int32) {
        writeHeader(tag, wireType: .varint)
        writeVarint(UInt64(value))
    }

    public func writeBytesField(_ tag: UInt32, _ value: [UInt8]) {
        writeHeader(tag, wireType: .bytes)
        writeVarint(UInt64(value.count))
        ensure(value.count)
        for b in value { buf[pos] = b; pos += 1 }
    }

    public func writeListField<T>(_ tag: UInt32, _ items: [T], _ writeFn: (ByteMsgWriter, T) -> Void) {
        writeHeader(tag, wireType: .bytes)
        let nested = ByteMsgWriter()
        nested.writeVarint(UInt64(items.count))
        for item in items { writeFn(nested, item) }
        let nb = nested.finish()
        writeVarint(UInt64(nb.count))
        ensure(nb.count)
        for b in nb { buf[pos] = b; pos += 1 }
    }

    public func writePackedVarints(_ tag: UInt32, _ values: [UInt64]) {
        writeHeader(tag, wireType: .bytes)
        let nested = ByteMsgWriter()
        nested.writeVarint(UInt64(values.count))
        for v in values { nested.writeVarint(v) }
        let nb = nested.finish()
        writeVarint(UInt64(nb.count))
        ensure(nb.count)
        for b in nb { buf[pos] = b; pos += 1 }
    }

    public func writeDeltaVarints(_ tag: UInt32, _ values: [UInt64]) {
        writeHeader(tag, wireType: .bytes)
        let nested = ByteMsgWriter()
        nested.writeVarint(UInt64(values.count))
        if !values.isEmpty {
            var prev = values[0]
            nested.writeVarint(prev)
            for i in 1..<values.count {
                nested.writeVarint(zigzagEncode(Int64(values[i]) - Int64(prev)))
                prev = values[i]
            }
        }
        let nb = nested.finish()
        writeVarint(UInt64(nb.count))
        ensure(nb.count)
        for b in nb { buf[pos] = b; pos += 1 }
    }

    public func writeBoolBitset(_ tag: UInt32, _ values: [Bool]) {
        writeHeader(tag, wireType: .bytes)
        let nested = ByteMsgWriter()
        nested.writeVarint(UInt64(values.count))
        var current: UInt8 = 0
        for (i, v) in values.enumerated() {
            if v { current |= 1 << UInt8(i & 7) }
            if (i & 7) == 7 { nested.ensure(1); nested.buf[nested.pos] = current; nested.pos += 1; current = 0 }
        }
        if values.count & 7 != 0 { nested.ensure(1); nested.buf[nested.pos] = current; nested.pos += 1 }
        let nb = nested.finish()
        writeVarint(UInt64(nb.count))
        ensure(nb.count)
        for b in nb { buf[pos] = b; pos += 1 }
    }

    public func writeStringList(_ tag: UInt32, _ values: [String]) {
        writeHeader(tag, wireType: .bytes)
        let nested = ByteMsgWriter()
        nested.writeVarint(UInt64(values.count))
        for v in values { nested.writeStringValue(v) }
        let nb = nested.finish()
        writeVarint(UInt64(nb.count))
        ensure(nb.count)
        for b in nb { buf[pos] = b; pos += 1 }
    }
}

public final class ByteMsgReader {
    private let data: [UInt8]
    private var pos: Int = 0

    public var eof: Bool { pos >= data.count }
    public var remaining: Int { data.count - pos }

    public init(_ data: [UInt8]) {
        self.data = data
    }

    public func readFieldHeader() -> (tag: UInt32, wireType: ByteMsgWireType) {
        let raw = readVarint()
        let tag = UInt32(raw >> 3)
        let wt = ByteMsgWireType(rawValue: UInt8(raw & 0x7)) ?? .varint
        return (tag, wt)
    }

    public func readVarint() -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt = 0
        while shift < 64 {
            if pos >= data.count { return 0 }
            let b = data[pos]
            pos += 1
            value |= UInt64(b & 0x7F) << shift
            if b < 0x80 { return value }
            shift += 7
        }
        return value
    }

    public func readVarintUInt32() -> UInt32 { UInt32(readVarint()) }
    public func readVarintInt32() -> Int32 { Int32(bitPattern: UInt32(readVarint())) }
    public func readVarintInt64() -> Int64 { zigzagDecode(readVarint()) }

    public func readFixed32() -> UInt32 {
        guard data.count - pos >= 4 else { return 0 }
        let v = UInt32(data[pos]) | (UInt32(data[pos + 1]) << 8) | (UInt32(data[pos + 2]) << 16) | (UInt32(data[pos + 3]) << 24)
        pos += 4
        return v
    }

    public func readFixed64() -> UInt64 {
        guard data.count - pos >= 8 else { return 0 }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(data[pos + i]) << (UInt(i) * 8) }
        pos += 8
        return v
    }

    public func readFloat() -> Float { Float(bitPattern: readFixed32()) }
    public func readDouble() -> Double { Double(bitPattern: readFixed64()) }
    public func readBool() -> Bool { readVarint() != 0 }
    public func readEnum() -> Int32 { Int32(readVarint()) }

    public func readString() -> String {
        let len = Int(readVarint())
        guard len <= data.count - pos else { return "" }
        let s = String(bytes: data[pos..<pos + len], encoding: .utf8) ?? ""
        pos += len
        return s
    }

    public func readBytes() -> [UInt8] {
        let len = Int(readVarint())
        guard len <= data.count - pos else { return [] }
        let bytes = Array(data[pos..<pos + len])
        pos += len
        return bytes
    }

    public func skipField(_ wireType: ByteMsgWireType) {
        switch wireType {
        case .varint: _ = readVarint()
        case .fixed64: pos += 8
        case .bytes: let n = Int(readVarint()); pos += n
        case .fixed32: pos += 4
        }
    }

    public func readList<T>(_ readFn: (ByteMsgReader) -> T) -> [T] {
        let count = Int(readVarint())
        let len = Int(readVarint())
        let end = pos + len
        var items: [T] = []
        items.reserveCapacity(count)
        for _ in 0..<count { items.append(readFn(self)) }
        pos = end
        return items
    }

    public func readPackedVarints() -> [UInt64] {
        let count = Int(readVarint())
        let len = Int(readVarint())
        let end = pos + len
        var arr = [UInt64]()
        arr.reserveCapacity(count)
        for _ in 0..<count { arr.append(readVarint()) }
        pos = end
        return arr
    }

    public func readDeltaVarints() -> [UInt64] {
        let count = Int(readVarint())
        let len = Int(readVarint())
        let end = pos + len
        var arr = [UInt64]()
        arr.reserveCapacity(count)
        if count > 0 {
            var value = readVarint()
            arr.append(value)
            for _ in 1..<count {
                value = UInt64(Int64(bitPattern: value) + zigzagDecode(readVarint()))
                arr.append(value)
            }
        }
        pos = end
        return arr
    }

    public func readBoolBitset() -> [Bool] {
        let count = Int(readVarint())
        let len = Int(readVarint())
        let end = pos + len
        var arr = [Bool](repeating: false, count: count)
        var i = 0
        while i < count {
            let current = data[pos]; pos += 1
            let limit = min(8, count - i)
            for b in 0..<limit { arr[i + b] = (current & (1 << UInt8(b))) != 0 }
            i += 8
        }
        pos = end
        return arr
    }

    public func readStringList() -> [String] {
        let count = Int(readVarint())
        let len = Int(readVarint())
        let end = pos + len
        var items = [String]()
        items.reserveCapacity(count)
        for _ in 0..<count { items.append(readString()) }
        pos = end
        return items
    }
}

public struct ProtocolHello {
    public var version: UInt64
    public var minCompatible: UInt64

    public init(version: UInt64 = 0, minCompatible: UInt64 = 0) {
        self.version = version
        self.minCompatible = minCompatible
    }
}

public func appendProtocolHello(_ dst: [UInt8], _ hello: ProtocolHello) -> [UInt8] {
    let w = ByteMsgWriter(capacity: dst.count + 24)
    for b in dst { w.buf.append(b) } // simplified
    w.writeHeader(1, wireType: .varint)
    w.writeVarint(hello.version)
    w.writeHeader(2, wireType: .varint)
    w.writeVarint(hello.minCompatible)
    return w.finish()
}

public func readProtocolHello(_ data: [UInt8]) -> ProtocolHello {
    let r = ByteMsgReader(data)
    var hello = ProtocolHello()
    while !r.eof {
        let h = r.readFieldHeader()
        switch h.tag {
        case 1: hello.version = r.readVarint()
        case 2: hello.minCompatible = r.readVarint()
        default: r.skipField(h.wireType)
        }
    }
    return hello
}

public func checkProtocolHello(_ local: ProtocolHello, _ remote: ProtocolHello) -> Bool {
    return remote.version >= local.minCompatible && local.version >= remote.minCompatible
}
