import XCTest
import zlib
@testable import FileFlipper

final class ZipArchiveTests: XCTestCase {
    func testStoredAndDeflatedEntriesIncludingEmptyFiles() throws {
        for name in ["stored.zip", "deflated.zip"] {
            let archive = try ZipArchive(data: fixture(name))
            XCTAssertEqual(archive.data(at: "hello.txt"), Data("Hello, FileFlipper!".utf8))
            XCTAssertEqual(archive.data(at: "empty.txt"), Data())
            XCTAssertNil(archive.data(at: "missing"))
        }
    }

    func testEveryTruncationIsRejectedWithoutCrashing() throws {
        let bytes = try fixture("deflated.zip")
        for length in 0..<bytes.count {
            XCTAssertThrowsError(try ZipArchive(data: bytes.prefix(length)), "length \(length)")
        }
    }

    func testCentralDirectoryNameCannotRunPastItsEnd() throws {
        var bytes = try fixture("stored.zip")
        bytes.set16(0xffff, at: bytes.centralOffset + 28)
        XCTAssertThrowsError(try ZipArchive(data: bytes))
    }

    func testCentralExtraAndCommentLengthsAreBounded() throws {
        for field in [30, 32] {
            var bytes = try fixture("stored.zip")
            bytes.set16(0xffff, at: bytes.centralOffset + field)
            XCTAssertThrowsError(try ZipArchive(data: bytes))
        }
    }

    func testLocalHeaderOutsideArchiveIsRejected() throws {
        var bytes = try fixture("stored.zip")
        bytes.set32(UInt32.max, at: bytes.centralOffset + 42)
        XCTAssertThrowsError(try ZipArchive(data: bytes))
    }

    func testLocalNameAndExtraLengthsAreBounded() throws {
        for field in [26, 28] {
            var bytes = try fixture("stored.zip")
            bytes.set16(0xffff, at: field)
            XCTAssertThrowsError(try ZipArchive(data: bytes))
        }
    }

    func testCompressedPayloadCannotOverlapDirectory() throws {
        var bytes = try fixture("deflated.zip")
        bytes.set32(UInt32.max, at: bytes.centralOffset + 20)
        XCTAssertThrowsError(try ZipArchive(data: bytes))
    }

    func testOversizedDeclarationIsRejectedBeforeAllocation() throws {
        var bytes = try fixture("deflated.zip")
        bytes.set32(UInt32.max, at: bytes.centralOffset + 24)
        XCTAssertThrowsError(try ZipArchive(data: bytes))
    }

    func testArchiveEntryCountAndAggregateBudgets() throws {
        let bytes = makeZIP([("a", Data(repeating: 1, count: 6)), ("b", Data(repeating: 2, count: 6))])
        XCTAssertThrowsError(try ZipArchive(data: bytes, limits: .init(archiveBytes: bytes.count - 1)))
        XCTAssertThrowsError(try ZipArchive(data: bytes, limits: .init(entryBytes: 5)))
        XCTAssertThrowsError(try ZipArchive(data: bytes, limits: .init(totalBytes: 10)))
        XCTAssertThrowsError(try ZipArchive(data: bytes, limits: .init(entries: 1)))
        XCTAssertNotNil(try ZipArchive(data: bytes, limits: .init(entryBytes: 6, totalBytes: 12, entries: 2)))
    }

    func testBoundedFileRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try fixture("stored.zip").write(to: url)
        XCTAssertThrowsError(try ZipArchive(url: url, limits: .init(archiveBytes: 32)))
    }

    func testEncryptionMultidiskAndUnsupportedMethodsAreRejected() throws {
        for (field, value) in [(8, UInt16(1)), (10, UInt16(99)), (34, UInt16(1))] {
            var bytes = try fixture("stored.zip")
            bytes.set16(value, at: bytes.centralOffset + field)
            XCTAssertThrowsError(try ZipArchive(data: bytes))
        }
        var bytes = try fixture("stored.zip")
        bytes.set16(1, at: bytes.count - 22 + 4)
        XCTAssertThrowsError(try ZipArchive(data: bytes))
    }

    func testDuplicateNamesAndOverlappingLocalRecordsAreRejected() throws {
        XCTAssertThrowsError(try ZipArchive(data: makeZIP([("same", Data()), ("same", Data())])))
        var bytes = try fixture("stored.zip")
        let first = bytes.centralOffset
        let second = first + 46 + "hello.txt".utf8.count
        bytes.set32(0, at: second + 42)
        XCTAssertThrowsError(try ZipArchive(data: bytes))
    }

    func testStoredChecksumDetectsCorruption() throws {
        var bytes = try fixture("stored.zip")
        bytes[30 + "hello.txt".utf8.count] ^= 1
        XCTAssertNil(try ZipArchive(data: bytes).data(at: "hello.txt"))
    }

    func testDeflateMustFinishAtDeclaredSize() throws {
        for size in [UInt32(1), UInt32(100)] {
            var bytes = try fixture("deflated.zip")
            bytes.set32(size, at: 22)
            bytes.set32(size, at: bytes.centralOffset + 24)
            XCTAssertNil(try ZipArchive(data: bytes).data(at: "hello.txt"))
        }
    }

    func testDeflateRejectsTruncatedStreamAndBadChecksum() throws {
        var bytes = try fixture("deflated.zip")
        let compressed = bytes.read32(at: 18)
        bytes.set32(compressed - 1, at: 18)
        bytes.set32(compressed - 1, at: bytes.centralOffset + 20)
        XCTAssertNil(try ZipArchive(data: bytes).data(at: "hello.txt"))
        bytes = try fixture("deflated.zip")
        bytes.set32(0, at: 14)
        bytes.set32(0, at: bytes.centralOffset + 16)
        XCTAssertNil(try ZipArchive(data: bytes).data(at: "hello.txt"))
    }

    func testArchiveCommentAndDataDescriptorFlagRemainSupported() throws {
        var bytes = try fixture("deflated.zip")
        bytes.set16(3, at: bytes.count - 2)
        bytes.append(contentsOf: [65, 66, 67])
        XCTAssertEqual(try ZipArchive(data: bytes).data(at: "hello.txt"), Data("Hello, FileFlipper!".utf8))
        bytes = makeZIP([("test", Data("descriptor".utf8))], dataDescriptor: true)
        XCTAssertEqual(try ZipArchive(data: bytes).data(at: "test"), Data("descriptor".utf8))
    }

    func testXMLRejectsDoctypeExternalEntitiesAndDeepNesting() throws {
        for text in [
            "<!DOCTYPE root [<!ENTITY x SYSTEM 'file:///nonexistent'>]><root>&x;</root>",
            "<!DOCTYPE root [<!ENTITY x 'repeated'>]><root>&x;</root>",
            String(repeating: "<a>", count: 129) + String(repeating: "</a>", count: 129)
        ] {
            for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian] {
                var data = text.data(using: encoding)!
                if encoding == .utf16LittleEndian { data.insert(contentsOf: [0xff, 0xfe], at: 0) }
                if encoding == .utf16BigEndian { data.insert(contentsOf: [0xfe, 0xff], at: 0) }
                let archive = try ZipArchive(data: makeZIP([("document.xml", data)]))
                XCTAssertNil(OfficePackage.xml(archive, "document.xml"))
            }
        }
    }

    func testXMLAcceptsOrdinaryUnicodeAndBuiltInEscapes() throws {
        let text = "<root><text>文件 &amp; café</text></root>"
        for encoding in [String.Encoding.utf8, .utf16] {
            let archive = try ZipArchive(data: makeZIP([("document.xml", text.data(using: encoding)!)]))
            XCTAssertEqual(OfficePackage.xml(archive, "document.xml")?.child("text")?.stringValue, "文件 & café")
        }
    }

    func testXMLSizeAndNodeLimits() throws {
        for data in [Data(repeating: 32, count: 16 * 1024 * 1024 + 1),
                     Data(("<root>" + String(repeating: "<a/>", count: 250_001) + "</root>").utf8)] {
            let archive = try ZipArchive(data: makeZIP([("document.xml", data)]))
            XCTAssertNil(OfficePackage.xml(archive, "document.xml"))
        }
    }
}

func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!)
}

/// Tiny ZIP fixture writer: stored entries, UTF-8 names, CRC32 and optional descriptors.
func makeZIP(_ entries: [(String, Data)], dataDescriptor: Bool = false) -> Data {
    var result = Data(), central = Data()
    for (name, bytes) in entries {
        let nameData = Data(name.utf8)
        let offset = UInt32(result.count), size = UInt32(bytes.count)
        let crc = bytes.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))) }
        let flags: UInt16 = dataDescriptor ? 0x0808 : 0x0800
        result.append32(0x04034b50); result.append16(20); result.append16(flags); result.append16(0)
        result.append32(0); result.append32(dataDescriptor ? 0 : crc)
        result.append32(dataDescriptor ? 0 : size); result.append32(dataDescriptor ? 0 : size)
        result.append16(UInt16(nameData.count)); result.append16(0); result.append(nameData); result.append(bytes)
        if dataDescriptor { result.append32(0x08074b50); result.append32(crc); result.append32(size); result.append32(size) }
        central.append32(0x02014b50); central.append16(20); central.append16(20); central.append16(flags)
        central.append16(0); central.append32(0); central.append32(crc); central.append32(size); central.append32(size)
        central.append16(UInt16(nameData.count)); central.append16(0); central.append16(0); central.append16(0)
        central.append16(0); central.append32(0); central.append32(offset); central.append(nameData)
    }
    let offset = UInt32(result.count)
    result.append(central); result.append32(0x06054b50); result.append16(0); result.append16(0)
    result.append16(UInt16(entries.count)); result.append16(UInt16(entries.count))
    result.append32(UInt32(central.count)); result.append32(offset); result.append16(0)
    return result
}

extension Data {
    var centralOffset: Int { Int(read32(at: count - 6)) }
    func read32(at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(self[offset + $1]) << ($1 * 8) }
    }
    mutating func set16(_ value: UInt16, at offset: Int) {
        for index in 0..<2 { self[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
    mutating func set32(_ value: UInt32, at offset: Int) {
        for index in 0..<4 { self[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
    mutating func append16(_ value: UInt16) {
        append(contentsOf: (0..<2).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    mutating func append32(_ value: UInt32) {
        append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
}
