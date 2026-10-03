import XCTest
import AppKit
import ImageIO
@testable import FileFlipper

final class ConversionTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FileFlipperTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testNormalWordSpreadsheetAndPresentationConversions() throws {
        for (name, expected) in [("sample.docx", "Hello from Word"), ("sample.xlsx", "42"), ("sample.pptx", "Hello from Slides")] {
            let input = directory.appendingPathComponent(name)
            let original = try fixture(name)
            try original.write(to: input)
            let output: String
            switch input.pathExtension {
            case "docx": output = try WordMarkdown.markdown(input)
            case "xlsx": output = try String(contentsOf: SpreadsheetConverter.toMarkdown(input), encoding: .utf8)
            default: output = try String(contentsOf: PresentationConverter.toMarkdown(input), encoding: .utf8)
            }
            XCTAssertTrue(output.contains(expected), output)
            XCTAssertEqual(try Data(contentsOf: input), original)
        }
    }

    func testBatchConversionKeepsExactSourceMappingAfterFailureAndNameCollision() throws {
        let broken = directory.appendingPathComponent("broken.xlsx")
        let source = directory.appendingPathComponent("sample.xlsx")
        let existing = directory.appendingPathComponent("sample.md")
        try Data("invalid Office file".utf8).write(to: broken)
        let original = try fixture("sample.xlsx")
        try original.write(to: source)
        let sentinel = Data("keep this file".utf8)
        try sentinel.write(to: existing)
        let item = try XCTUnwrap(Catalog.items(for: [broken, source], tools: false).first { $0.title == "MD" })
        let results = try item.action([broken, source])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].sources, [source])
        XCTAssertEqual(results[0].url.deletingLastPathComponent(), source.deletingLastPathComponent())
        XCTAssertEqual(results[0].url.lastPathComponent, "sample 2.md")
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        XCTAssertTrue(try String(contentsOf: results[0].url).contains("42"))
    }

    func testSpreadsheetRejectsHugeSparseGridAndInvalidCoordinates() throws {
        let input = directory.appendingPathComponent("grid.xlsx")
        try spreadsheet(cells: "<c r='A1'><v>1</v></c><c r='XFD1048576'><v>2</v></c>").write(to: input)
        XCTAssertThrowsError(try SpreadsheetConverter.read(input))
        try spreadsheet(cells: "<c r='A1'><v>1</v></c><c r='ZZZZZZZZZZZZZZZZZZZZZZZZ1'><v>2</v></c><c r='A1B2'><v>3</v></c>").write(to: input)
        XCTAssertEqual(try SpreadsheetConverter.read(input).first?.rows, [["1"]])
    }

    func testNonFiniteSpreadsheetNumberStaysText() throws {
        let input = directory.appendingPathComponent("number.xlsx")
        try spreadsheet(cells: "<c r='A1'><v>inf</v></c>").write(to: input)
        XCTAssertEqual(try SpreadsheetConverter.read(input).first?.rows, [["inf"]])
    }

    func testWordIndentationCannotBeNegativeOrUnbounded() throws {
        let input = directory.appendingPathComponent("list.docx")
        for level in ["-9223372036854775808", "9223372036854775807", "-1", "2"] {
            let xml = "<w:document xmlns:w='urn:word'><w:body><w:p><w:pPr><w:numPr><w:numId w:val='1'/><w:ilvl w:val='\(level)'/></w:numPr></w:pPr><w:r><w:t>Item</w:t></w:r></w:p></w:body></w:document>"
            try makeZIP([("word/document.xml", Data(xml.utf8))]).write(to: input)
            let output = try WordMarkdown.markdown(input)
            XCTAssertTrue(output.contains("Item"))
            XCTAssertLessThan(output.count, 100)
        }
    }

    func testPresentationIndentationCannotBeNegativeOrUnbounded() throws {
        let input = directory.appendingPathComponent("list.pptx")
        let archive = try ZipArchive(data: fixture("sample.pptx"))
        for level in ["-9223372036854775808", "9223372036854775807", "-1", "2"] {
            let entries = archive.paths.map { path -> (String, Data) in
                let data = archive.data(at: path)!
                guard path == "ppt/slides/slide1.xml" else { return (path, data) }
                let xml = String(decoding: data, as: UTF8.self).replacingOccurrences(
                    of: "<a:p>", with: "<a:p><a:pPr lvl='\(level)'><a:buChar char='•'/></a:pPr>")
                return (path, Data(xml.utf8))
            }
            try makeZIP(entries).write(to: input)
            let output = try String(contentsOf: PresentationConverter.toMarkdown(input), encoding: .utf8)
            XCTAssertTrue(output.contains("Hello from Slides"))
            XCTAssertLessThan(output.count, 200)
        }
    }

    func testPNGToJPEGRetainsInputAndExistingOutput() throws {
        let input = directory.appendingPathComponent("sample.png")
        let existing = directory.appendingPathComponent("sample.jpg")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        for index in 0..<16 { bitmap.bitmapData![index] = (index % 4 == 0 || index % 4 == 3) ? 255 : 0 }
        let original = bitmap.representation(using: .png, properties: [:])!
        try original.write(to: input)
        let sentinel = Data("existing file".utf8)
        try sentinel.write(to: existing)
        let output = try ImageConverter.convert(input, to: .jpeg, ext: "jpg")
        XCTAssertEqual(output.lastPathComponent, "sample 2.jpg")
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 2); XCTAssertEqual(image.height, 2)
    }

    private func spreadsheet(cells: String) -> Data {
        makeZIP([
            ("xl/workbook.xml", Data("<workbook xmlns:r='urn:relationships'><sheets><sheet name='Test' r:id='rId1'/></sheets></workbook>".utf8)),
            ("xl/_rels/workbook.xml.rels", Data("<Relationships><Relationship Id='rId1' Target='worksheets/sheet1.xml'/></Relationships>".utf8)),
            ("xl/worksheets/sheet1.xml", Data("<worksheet><sheetData><row>\(cells)</row></sheetData></worksheet>".utf8))
        ])
    }
}
