# bytemsg233-lib-swift

Swift runtime for `bytemsg233` generated code.

This repository provides encode/decode helpers, object pool, and enum utilities for generated Swift structs and classes. Works on iOS, macOS, Linux, and server-side Swift.

## Features

- Pool rent / return for zero-GC game hot paths
- Native `enum` support with `Int` raw value
- Varint, zigzag, string, bytes, list, map, nested message support
- Single-threaded by design: no locks, no DispatchQueue, no background workers
- iOS, macOS, Linux, and server-side Swift compatible
- Zero external dependencies

## Install

Copy-based install from the main repository:

```bash
bytemsg233 install-lib swift --to ./Sources/bytemsg233
```

Or add as a git submodule:

```bash
git submodule add https://github.com/neko233-com/bytemsg233-lib-swift.git Sources/bytemsg233
```

## Quick Start

```swift
import ByteMsg233

enum HeroState: Int {
    case idle = 0
    case moving = 1
    case dead = 2

    static func fromValue(_ v: Int) -> HeroState {
        HeroState(rawValue: v) ?? .idle
    }
}

struct Hero {
    var id: UInt32 = 0
    var name: String = ""
    var state: HeroState = .idle
    var tags: [String] = []

    mutating func reset() {
        id = 0
        name = ""
        state = .idle
        tags.removeAll()
    }
}

extension Hero {
    private static let pool = ByteMsgPool { Hero() }

    static func rent() -> Hero { pool.rent() }
    func `return`() { pool.return(self) }

    func encode() -> [UInt8] {
        let writer = ByteMsgWriter()
        writer.writeUintField(1, id)
        writer.writeStringField(2, name)
        writer.writeEnumField(3, state.rawValue)
        writer.writeListField(4, tags) { w, v in w.writeString(v) }
        return writer.finish()
    }

    static func decode(_ data: [UInt8]) -> Hero {
        var hero = rent()
        let reader = ByteMsgReader(data)
        while !reader.eof {
            let header = reader.readFieldHeader()
            switch header.tag {
            case 1: hero.id = reader.readVarintUInt32()
            case 2: hero.name = reader.readString()
            case 3: hero.state = HeroState.fromValue(reader.readVarintInt32())
            case 4: hero.tags = reader.readList { $0.readString() }
            default: reader.skipField(header.wireType)
            }
        }
        return hero
    }
}
```

## API

- `ByteMsgWriter`: field header, scalar, string, bytes, list, map, nested message writing
- `ByteMsgReader`: field header, scalar reading, field skipping with bounded length checks
- `ByteMsgPool<T>`: single-threaded object pool with `rent()` / `return()`
- Enum helpers for `enum` value restore and validation

## Development

```bash
swift test
```
