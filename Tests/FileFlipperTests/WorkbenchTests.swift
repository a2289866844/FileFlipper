import XCTest
import AppKit
import SwiftUI
@testable import FileFlipper

final class WorkbenchTests: XCTestCase {
    func testSelectionDeduplicatesAndRejectsFoldersAndRemoteURLs() {
        let model = WorkbenchModel()
        let file = URL(fileURLWithPath: "/tmp/photo.png")
        model.setFiles([file, file, URL(fileURLWithPath: "/tmp", isDirectory: true), URL(string: "https://example.com/photo.png")!])
        XCTAssertEqual(model.files, [file])
        model.selectedTitle = "JPG"
        model.setFiles([URL(fileURLWithPath: "/tmp/second.png")], adding: true)
        XCTAssertEqual(model.files.count, 2)
        XCTAssertNil(model.selectedTitle)
    }

    func testMixedBatchCannotRunOrExposePartialActions() {
        let model = WorkbenchModel()
        let urls = [URL(fileURLWithPath: "/tmp/photo.png"), URL(fileURLWithPath: "/tmp/document.pdf")]
        model.setFiles(urls)
        model.selectedTitle = "JPG"
        XCTAssertTrue(model.hasMixedKinds)
        XCTAssertFalse(model.canRun)
        XCTAssertTrue(Catalog.items(for: urls, tools: false).isEmpty)
        XCTAssertTrue(Catalog.items(for: urls, tools: true).isEmpty)
    }

    func testRunRequiresSelectionAndBusyStateBlocksEditsAndDuplicateRuns() throws {
        let model = WorkbenchModel()
        let input = URL(fileURLWithPath: "/tmp/photo.png")
        model.setFiles([input])
        var runs = 0
        model.onRun = { item, files in runs += 1; model.begin(item, files: files) }
        model.runSelection()
        XCTAssertEqual(runs, 0)
        let item = try XCTUnwrap(model.items.first)
        model.selectedTitle = item.title
        XCTAssertTrue(model.canRun)
        model.runSelection()
        model.runSelection()
        model.setFiles([])
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(model.files, [input])
        XCTAssertTrue(model.isWorking)
        let output = URL(fileURLWithPath: "/tmp/photo.jpg")
        model.complete(results: [ConversionOutput(url: output, sources: [input])], message: "Saved photo.jpg")
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(model.outputs, [output])
        model.tools = true
        XCTAssertNil(model.selectedTitle)
        XCTAssertFalse(model.canRun)
    }

    func testResultsStayWithTheirSourcesAcrossRepeatedConversionsAndSelectionChanges() {
        let model = WorkbenchModel()
        let a = URL(fileURLWithPath: "/tmp/a/photo.png")
        let b = URL(fileURLWithPath: "/tmp/b/photo.png")
        model.setFiles([a, b])
        let first = ConversionOutput(url: b.deletingPathExtension().appendingPathExtension("jpg"), sources: [b])
        model.complete(results: [first], message: "Saved")
        XCTAssertTrue(model.results(after: a).isEmpty)
        XCTAssertEqual(model.results(after: b), [first])
        let second = ConversionOutput(url: b.deletingPathExtension().appendingPathExtension("tiff"), sources: [b])
        model.complete(results: [second], message: "Saved")
        XCTAssertEqual(model.results(after: b), [first, second])
        XCTAssertEqual(model.outputs, [second.url])
        model.remove(a)
        XCTAssertEqual(model.results(after: b), [first, second])
        model.setFiles([])
        XCTAssertTrue(model.results.isEmpty)
    }

    func testMergedResultAppearsOnceAndKeepsAllSourceReferences() {
        let model = WorkbenchModel()
        let a = URL(fileURLWithPath: "/tmp/a.png"), b = URL(fileURLWithPath: "/tmp/b.png")
        model.setFiles([a, b])
        let result = ConversionOutput(url: URL(fileURLWithPath: "/tmp/Merged.pdf"), sources: [a, b])
        model.complete(results: [result], message: "Saved")
        XCTAssertEqual(model.results(after: a), [result])
        XCTAssertTrue(model.results(after: b).isEmpty)
        model.remove(a)
        XCTAssertEqual(model.results(after: b), [result])
    }

    func testUnsupportedFilesHaveNoActions() {
        let model = WorkbenchModel()
        model.setFiles([URL(fileURLWithPath: "/tmp/archive.zip")])
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.canRun)
    }

    func testQuickPaletteOnlyAcceptsDropsInsideVisibleTiles() {
        let urls = [URL(fileURLWithPath: "/tmp/photo.png")]
        let items = Catalog.items(for: urls, tools: true)
        let view = BubbleArcView(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
        view.configure(items: items, urls: urls, tools: true)
        view.setFrameSize(view.preferredSize)
        for index in items.indices {
            let rect = view.tileRect(at: index)
            XCTAssertTrue(view.bounds.contains(rect))
            XCTAssertEqual(view.itemIndex(at: NSPoint(x: rect.midX, y: rect.midY)), index)
        }
        XCTAssertNil(view.itemIndex(at: NSPoint(x: 20, y: 20)))
        XCTAssertNil(view.itemIndex(at: NSPoint(x: 10, y: 100)))
        XCTAssertNil(view.itemIndex(at: NSPoint(x: 20, y: view.bounds.height - 10)))
    }

    /// Opt-in artifacts render only our own views, never other apps or the desktop.
    @MainActor func testRenderWorkbenchPreviews() throws {
        guard let path = ProcessInfo.processInfo.environment["FILEFLIPPER_PREVIEW_DIR"] else { throw XCTSkip("Opt-in UI rendering") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalBundle = Localization.bundle
        defer { Localization.bundle = originalBundle }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        Localization.bundle = try XCTUnwrap(Bundle(path: root.appendingPathComponent("Resources/Localization/zh-Hant.lproj").path))
        XCTAssertEqual(L("Convert files"), "轉換檔案")
        for dark in [false, true] {
            for state in ["empty", "files", "tools", "working", "success", "mixed", "error"] {
                let model = WorkbenchModel()
                if state != "empty" {
                    model.setFiles([URL(fileURLWithPath: "/tmp/溫哥華週末.heic"), URL(fileURLWithPath: state == "mixed" ? "/tmp/Notes.pdf" : "/tmp/海港日落.heic")])
                    model.selectedTitle = "JPG"
                }
                if state == "tools" { model.tools = true; model.selectedTitle = L("Clean") }
                if state == "working", let item = model.selectedItem { model.begin(item, files: model.files) }
                if state == "error" { model.complete(results: [], message: L("Folder access was not granted. Choose a folder when you try again."), failed: true) }
                if state == "success" {
                    model.complete(results: model.files.map { ConversionOutput(url: $0.deletingPathExtension().appendingPathExtension("jpg"), sources: [$0]) }, message: L("Saved %@ files", String(model.files.count)))
                }
                let content = WorkbenchView(model: model).frame(width: 790, height: 640)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.controlActiveState, .key)
                let host = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 790, height: 640),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.orderBack(nil)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("workbench-\(dark ? "dark" : "light")-\(state).png"))
                window.close()
            }
            let urls = [URL(fileURLWithPath: "/tmp/Weekend in Vancouver.heic")]
            let view = BubbleArcView(frame: .zero)
            view.configure(items: Catalog.items(for: urls, tools: true), urls: urls, tools: true)
            view.frame.size = view.preferredSize
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("quick-tools-\(dark ? "dark" : "light").png"))
        }
    }
}
