import Foundation
import zlib

/// Bounded, read-only ZIP reader for Office packages. ZIP64, encryption and
/// multi-disk archives are intentionally unsupported.
struct ZipArchive {
    struct Limits {
        var archiveBytes = 256 * 1024 * 1024
        var entryBytes = 64 * 1024 * 1024
        var totalBytes = 256 * 1024 * 1024
        var entries = 10_000
    }

    private struct Entry {
        let method: UInt16
        let size: Int
        let checksum: UInt32
        let payload: Range<Int>
    }

    private let data: Data
    private var entries: [String: Entry] = [:]

    init(url: URL, limits: Limits = Limits()) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        // Bound the read itself, including if a file grows after being opened.
        var bytes = Data()
        while true {
            let remaining = max(0, limits.archiveBytes - bytes.count)
            let chunk = try file.read(upToCount: min(64 * 1024, remaining + 1)) ?? Data()
            if chunk.isEmpty { break }
            guard chunk.count <= remaining else { throw Self.invalidArchive() }
            bytes.append(chunk)
        }
        try self.init(data: bytes, limits: limits)
    }

    init(data: Data, limits: Limits = Limits()) throws {
        // Normalize Data's indices (callers may pass a slice).
        self.data = Data(data)
        guard limits.archiveBytes > 0, limits.entryBytes >= 0,
              limits.entryBytes < Int(UInt32.max), limits.totalBytes >= 0,
              limits.entries > 0, data.count <= limits.archiveBytes else {
            throw Self.invalidArchive()
        }
        try readCentralDirectory(limits: limits)
    }

    var paths: [String] { Array(entries.keys) }
    func contains(_ path: String) -> Bool { entries[path] != nil }

    func data(at path: String) -> Data? {
        guard let entry = entries[path] else { return nil }
        let compressed = data.subdata(in: entry.payload)
        var output: Data
        if entry.method == 0 {
            output = compressed
        } else {
            // An extra byte detects streams that expand beyond the declared size.
            output = Data(count: entry.size + 1)
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION,
                                Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
            defer { inflateEnd(&stream) }
            let status = output.withUnsafeMutableBytes { destination in
                compressed.withUnsafeBytes { source -> Int32 in
                    stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(compressed.count)
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(entry.size + 1)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard status == Z_STREAM_END, stream.total_out == entry.size,
                  stream.total_in == compressed.count else { return nil }
            output.count = entry.size
        }
        let checksum = output.withUnsafeBytes {
            UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(output.count)))
        }
        return checksum == entry.checksum ? output : nil
    }

    private mutating func readCentralDirectory(limits: Limits) throws {
        guard data.count >= 22 else { throw Self.invalidArchive() }
        let lowest = max(0, data.count - 65_557)
        // Match the entire EOCD including its comment; a signature in a comment
        // must not be mistaken for a truncated end record.
        guard let end = stride(from: data.count - 22, through: lowest, by: -1).first(where: {
            uint32(at: $0) == 0x0605_4b50 && $0 + 22 + Int(uint16(at: $0 + 20)) == data.count
        }) else { throw Self.invalidArchive() }
        let count = Int(uint16(at: end + 10))
        let directorySize = Int(uint32(at: end + 12))
        let directoryStart = Int(uint32(at: end + 16))
        guard uint16(at: end + 4) == 0, uint16(at: end + 6) == 0,
              uint16(at: end + 8) == count, count > 0, count < 0xffff,
              count <= limits.entries, contains(directoryStart, directorySize, before: end),
              directoryStart + directorySize == end else { throw Self.invalidArchive() }

        var offset = directoryStart
        var total = 0
        var localRecords: [Range<Int>] = []
        for _ in 0..<count {
            guard contains(offset, 46, before: end), uint32(at: offset) == 0x0201_4b50 else {
                throw Self.invalidArchive()
            }
            let flags = uint16(at: offset + 8)
            let method = uint16(at: offset + 10)
            let checksum = uint32(at: offset + 16)
            let compressedSize = Int(uint32(at: offset + 20))
            let size = Int(uint32(at: offset + 24))
            let nameLength = Int(uint16(at: offset + 28))
            let extraLength = Int(uint16(at: offset + 30))
            let commentLength = Int(uint16(at: offset + 32))
            let header = Int(uint32(at: offset + 42))
            let recordSize = 46 + nameLength + extraLength + commentLength
            // Permit deflate options, data descriptors and UTF-8 names only.
            guard flags & ~UInt16(0x080e) == 0, method == 0 || method == 8,
                  uint16(at: offset + 34) == 0, nameLength > 0,
                  contains(offset, recordSize, before: end), size <= limits.entryBytes,
                  size <= limits.totalBytes - total,
                  contains(header, 30, before: directoryStart),
                  uint32(at: header) == 0x0403_4b50,
                  uint16(at: header + 6) == flags, uint16(at: header + 8) == method else {
                throw Self.invalidArchive()
            }
            let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
            guard let name = String(data: nameData, encoding: .utf8), !name.contains("\0"),
                  entries[name] == nil, Int(uint16(at: header + 26)) == nameLength else {
                throw Self.invalidArchive()
            }
            let localSize = 30 + nameLength + Int(uint16(at: header + 28))
            guard contains(header, localSize, before: directoryStart),
                  data.subdata(in: (header + 30)..<(header + 30 + nameLength)) == nameData else {
                throw Self.invalidArchive()
            }
            let start = header + localSize
            guard contains(start, compressedSize, before: directoryStart),
                  method != 0 || compressedSize == size,
                  method != 8 || compressedSize > 0 else { throw Self.invalidArchive() }
            if flags & 8 == 0 {
                guard uint32(at: header + 14) == checksum,
                      uint32(at: header + 18) == compressedSize,
                      uint32(at: header + 22) == size else { throw Self.invalidArchive() }
            }
            let payload = start..<(start + compressedSize)
            entries[name] = Entry(method: method, size: size, checksum: checksum, payload: payload)
            localRecords.append(header..<payload.upperBound)
            total += size
            offset += recordSize
        }
        guard offset == end else { throw Self.invalidArchive() }
        // Do not allow multiple entries to alias or overlap the same payload.
        let sorted = localRecords.sorted { $0.lowerBound < $1.lowerBound }
        for index in 1..<sorted.count where sorted[index].lowerBound < sorted[index - 1].upperBound {
            throw Self.invalidArchive()
        }
    }

    private func contains(_ offset: Int, _ length: Int, before end: Int) -> Bool {
        offset >= 0 && length >= 0 && end <= data.count && offset <= end && length <= end - offset
    }

    private func uint16(at offset: Int) -> UInt16 {
        guard contains(offset, 2, before: data.count) else { return 0 }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func uint32(at offset: Int) -> UInt32 {
        guard contains(offset, 4, before: data.count) else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * $1) }
    }

    private static func invalidArchive() -> ConversionError {
        .message(L("This Office file is damaged, unsupported, or exceeds safe size limits"))
    }
}

// MARK: - XML helpers shared by the Office converters

extension XMLElement {
    /// Direct children with this local name (namespace prefix ignored).
    func children(_ name: String) -> [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == name }
    }

    func child(_ name: String) -> XMLElement? {
        (children ?? []).lazy.compactMap { $0 as? XMLElement }.first { $0.localName == name }
    }

    /// First descendant with this local name, depth first.
    func descendant(_ name: String) -> XMLElement? {
        for case let element as XMLElement in children ?? [] {
            if element.localName == name { return element }
            if let found = element.descendant(name) { return found }
        }
        return nil
    }

    func descendants(_ name: String) -> [XMLElement] {
        var found: [XMLElement] = []
        for case let element as XMLElement in children ?? [] {
            if element.localName == name { found.append(element) }
            found += element.descendants(name)
        }
        return found
    }

    /// Attribute by local name (so "r:embed" is just "embed").
    func attr(_ name: String) -> String? {
        attributes?.first { $0.localName == name }?.stringValue
    }

    /// The relationship id ("r:id"), which can share its local name with a plain "id" attribute.
    var relationshipID: String? {
        attributes?.first { $0.localName == "id" && ($0.prefix == "r" || ($0.uri ?? "").contains("relationships")) }?.stringValue
    }
}

enum OfficePackage {
    static func xml(_ archive: ZipArchive, _ path: String) -> XMLElement? {
        guard let data = archive.data(at: path),
              XMLSafety.accepts(data),
              let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]) else { return nil }
        return document.rootElement()
    }

    /// Relationship id → absolute package path, for the part at `path`.
    static func relationships(_ archive: ZipArchive, for path: String) -> [String: (target: String, type: String)] {
        let directory = (path as NSString).deletingLastPathComponent
        let relsPath = directory + "/_rels/" + (path as NSString).lastPathComponent + ".rels"
        guard let root = xml(archive, relsPath) else { return [:] }
        var result: [String: (String, String)] = [:]
        for relationship in root.children("Relationship") {
            guard let id = relationship.attr("Id"), let target = relationship.attr("Target") else { continue }
            // External targets (web links) are kept as written.
            let external = relationship.attr("TargetMode") == "External"
            result[id] = (external ? target : resolve(target, from: directory), relationship.attr("Type") ?? "")
        }
        return result
    }

    /// Resolves "../media/image1.png" relative to a directory inside the package.
    static func resolve(_ target: String, from directory: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = directory.split(separator: "/").map(String.init)
        for piece in target.split(separator: "/") {
            if piece == ".." { _ = parts.popLast() } else if piece != "." { parts.append(String(piece)) }
        }
        return parts.joined(separator: "/")
    }
}

/// Office parts do not need DTDs. Validate before constructing a recursive DOM,
/// keeping external resources, entity expansion and excessive nesting out.
private final class XMLSafety: NSObject, XMLParserDelegate {
    private var depth = 0
    private var nodes = 0

    static func accepts(_ data: Data) -> Bool {
        guard data.count <= 16 * 1024 * 1024 else { return false }
        let prefix = Array(data.prefix(2))
        let encoding: String.Encoding
        if prefix == [0xff, 0xfe] || prefix == [0x3c, 0] {
            encoding = .utf16LittleEndian
        } else if prefix == [0xfe, 0xff] || prefix == [0, 0x3c] {
            encoding = .utf16BigEndian
        } else {
            encoding = .utf8
        }
        guard let text = String(data: data, encoding: encoding), !text.contains("\0"),
              !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { return false }
        let validator = XMLSafety()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = validator
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        depth += 1
        nodes += 1 + attributeDict.count
        if depth > 128 || nodes > 250_000 { parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        depth -= 1
    }
}
