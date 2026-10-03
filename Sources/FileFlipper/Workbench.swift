import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A visible, keyboard-accessible home for the same actions as the Finder picker.
final class WorkbenchModel: ObservableObject {
    @Published private(set) var files: [URL] = []
    @Published var tools = false { didSet { selectedTitle = nil } }
    @Published var selectedTitle: String?
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?
    @Published private(set) var failed = false
    @Published private(set) var outputs: [URL] = []
    var onRun: ((PickerItem, [URL]) -> Void)?

    var items: [PickerItem] { Catalog.items(for: files, tools: tools) }
    var selectedItem: PickerItem? { items.first { $0.title == selectedTitle } }
    var hasMixedKinds: Bool {
        guard let first = files.first else { return false }
        return files.contains { FileKind(url: $0) != FileKind(url: first) }
    }
    var canRun: Bool { !isWorking && !hasMixedKinds && selectedItem != nil && !files.isEmpty }

    func setFiles(_ urls: [URL], adding: Bool = false) {
        guard !isWorking else { return }
        var seen = Set<URL>()
        files = ((adding ? files : []) + urls).filter { url in
            url.isFileURL && !url.hasDirectoryPath &&
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true &&
            seen.insert(url.standardizedFileURL).inserted
        }
        selectedTitle = nil
        message = nil
        outputs = []
        failed = false
    }

    func remove(_ url: URL) { setFiles(files.filter { $0 != url }) }

    func chooseFiles() {
        guard !isWorking else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("Add files")
        panel.message = L("Choose the files you want to convert or edit.")
        if panel.runModal() == .OK { setFiles(panel.urls, adding: true) }
    }

    func runSelection() {
        guard canRun, let item = selectedItem else { return }
        onRun?(item, files)
    }

    func begin(_ item: PickerItem, files: [URL]) {
        guard !isWorking else { return }
        setFiles(files)
        selectedTitle = item.title
        isWorking = true
        failed = false
        outputs = []
        message = L("Working on %@…", item.title)
    }

    func complete(outputs: [URL], message: String, failed: Bool = false) {
        isWorking = false
        self.outputs = outputs
        self.message = message
        self.failed = failed
    }

    func revealOutputs() {
        guard !outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
    }
}

final class WorkbenchWindowController: NSWindowController {
    init(model: WorkbenchModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 790, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "FileFlipper"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.contentMinSize = NSSize(width: 720, height: 600)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("FileFlipperWorkbench")
        window.contentView = NSHostingView(rootView: WorkbenchView(model: model))
        super.init(window: window)
        if !window.setFrameUsingName("FileFlipperWorkbench") { window.center() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct WorkbenchView: View {
    @ObservedObject var model: WorkbenchModel
    @State private var dropTargeted = false
    @State private var showHelp = false
    private let accent = Color(nsColor: Palette.accent)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Convert and edit files")).font(.system(size: 25, weight: .semibold))
                    Text(L("Choose files, pick an action, and save a new copy."))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showHelp.toggle() } label: {
                    Image(systemName: "questionmark.circle").font(.system(size: 17))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(L("Keyboard shortcuts"))
                .accessibilityLabel(L("Keyboard shortcuts"))
                .popover(isPresented: $showHelp) { shortcuts.padding(22).frame(width: 335) }
            }
            HStack(alignment: .top, spacing: 24) {
                inputPane.frame(width: 260).frame(maxHeight: .infinity)
                optionsPane.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if let message = model.message { status(message) }
            Divider()
            HStack(spacing: 14) {
                Label(L("New files are saved beside the originals."), systemImage: "folder")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(action: model.runSelection) {
                    Text(model.isWorking ? L("Working…") : (model.tools ? L("Apply tool") : L("Convert files")))
                        .frame(minWidth: 104)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(accent)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!model.canRun)
            }
        }
        .padding(28)
        .frame(minWidth: 720, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
    }

    private var inputPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Your files")).font(.system(size: 13, weight: .semibold))
                Spacer()
                if !model.files.isEmpty {
                    Text(String(model.files.count)).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Button(L("Clear")) { model.setFiles([]) }.buttonStyle(.link).font(.system(size: 12))
                }
            }
            VStack(spacing: 0) {
                if model.files.isEmpty {
                    Spacer(minLength: 16)
                    ZStack {
                        RoundedRectangle(cornerRadius: 16).fill(accent.opacity(0.08)).frame(width: 72, height: 72)
                        Image(systemName: "doc.badge.plus").font(.system(size: 32, weight: .light)).foregroundStyle(accent)
                    }
                    Text(dropTargeted ? L("Drop to add files") : L("Drop your files here"))
                        .font(.system(size: 16, weight: .semibold)).padding(.top, 20)
                    Text(L("Images, documents, video and audio"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.top, 7).padding(.horizontal, 20)
                    Button(L("Choose files…"), action: model.chooseFiles)
                        .controlSize(.large).padding(.top, 22).keyboardShortcut("o", modifiers: .command)
                    Spacer(minLength: 16)
                    Text(L("Or use ⇧ while dragging in Finder"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 22)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.files, id: \.self) { url in
                                HStack(spacing: 10) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                        .resizable().frame(width: 32, height: 32).accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(url.lastPathComponent).font(.system(size: 12, weight: .medium))
                                            .lineLimit(1).truncationMode(.middle).help(url.lastPathComponent)
                                        Text(url.pathExtension.uppercased()).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 2)
                                    Button { model.remove(url) } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                                        .buttonStyle(.plain).foregroundStyle(.secondary)
                                        .accessibilityLabel(L("Remove %@ from selection", url.lastPathComponent))
                                }.padding(.vertical, 12).padding(.horizontal, 14)
                                Divider().padding(.horizontal, 14)
                            }
                        }
                    }
                    Button(L("Add files…"), action: model.chooseFiles).buttonStyle(.link)
                        .padding(16).keyboardShortcut("o", modifiers: .command)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(
                dropTargeted ? accent : Color(nsColor: .separatorColor).opacity(0.5),
                style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: model.files.isEmpty ? [5, 4] : [])))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted, perform: acceptDrop)
        }
        .disabled(model.isWorking)
    }

    private var optionsPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L("What would you like to do?")).font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            Picker(L("Action"), selection: $model.tools) {
                Text(L("Convert")).tag(false)
                Text(L("Quick tools")).tag(true)
            }.pickerStyle(.segmented).labelsHidden().disabled(model.isWorking)
            if model.files.isEmpty {
                VStack(alignment: .leading, spacing: 20) {
                    Text(L("Start with a file."))
                        .font(.system(size: 18, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    example("photo", title: L("Images"), detail: "HEIC  →  JPG, PNG, PDF")
                    example("doc.text", title: L("Documents"), detail: "Word, PDF  →  Markdown")
                    example("film", title: L("Video & audio"), detail: "MOV  →  MP4, GIF, M4A")
                    Text(L("Add a file to see its available formats and tools."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 8)
            } else if model.hasMixedKinds {
                emptyOptions(symbol: "square.stack.3d.up.slash", title: L("Choose one file type at a time"),
                             detail: L("Keep images, documents and media in separate batches so every selected file is processed."))
            } else if model.items.isEmpty {
                emptyOptions(symbol: "doc.questionmark", title: model.tools ? L("No tools for these files") : L("This format isn't supported yet"),
                             detail: model.tools ? L("Try the Convert tab, or choose another file.") : L("Choose an image, PDF, Office document, video or audio file."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                        ForEach(model.items, id: \.title) { item in actionButton(item) }
                    }.padding(2)
                }.scrollIndicators(.visible)
                Text(model.selectedItem?.detail ?? (model.selectedItem.map { L("Save as %@", $0.title) } ?? L("Choose a format or tool to continue.")))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    .frame(minHeight: 30, alignment: .topLeading)
            }
            Spacer(minLength: 0)
        }
    }

    private func actionButton(_ item: PickerItem) -> some View {
        let selected = model.selectedTitle == item.title
        return Button { model.selectedTitle = item.title } label: {
            VStack(spacing: 8) {
                Image(systemName: item.symbol ?? Catalog.formatSymbol(for: item.title))
                    .font(.system(size: 21, weight: .regular)).frame(height: 24)
                Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(selected ? accent : Color.primary)
            .frame(maxWidth: .infinity).frame(height: 76)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? accent.opacity(0.09) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? accent : Color(nsColor: .separatorColor).opacity(0.35), lineWidth: selected ? 1.5 : 1))
            .overlay(alignment: .topTrailing) {
                if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(accent).padding(7) }
            }
        }
        .buttonStyle(.plain).disabled(model.isWorking)
        .accessibilityLabel(item.detail ?? L("Save as %@", item.title))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(item.detail ?? item.title)
    }

    private func example(_ symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 19, weight: .regular)).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func emptyOptions(symbol: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 16, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 20)
    }

    private func status(_ message: String) -> some View {
        HStack(spacing: 10) {
            if model.isWorking { ProgressView().controlSize(.small) }
            else { Image(systemName: model.failed ? "exclamationmark.circle.fill" : (model.outputs.isEmpty ? "info.circle" : "checkmark.circle.fill"))
                .foregroundStyle(model.failed ? Color.orange : accent) }
            Text(message).font(.system(size: 12)).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 6)
            if !model.outputs.isEmpty {
                Button(L("Show in Finder"), action: model.revealOutputs).controlSize(.small)
            }
        }.padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill((model.failed ? Color.orange : accent).opacity(0.07)))
        .accessibilityElement(children: .contain)
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Faster from Finder")).font(.system(size: 17, weight: .semibold))
            Text(L("Start dragging a file, then hold a shortcut. Drop onto an option to apply it."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack { Text(L("Convert formats")); Spacer(); Text("⇧").font(.system(size: 19)) }
            HStack { Text(L("Quick tools")); Spacer(); Text("⌥ ⇧").font(.system(size: 19)) }
            Divider()
            Text(L("Only the folder you save into needs permission. You can choose it when asked."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.isWorking else { return false }
        let collector = DroppedURLs()
        let group = DispatchGroup()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                if let url { collector.append(url) }
            }
        }
        group.notify(queue: .main) { model.setFiles(collector.urls, adding: true) }
        return true
    }
}

private final class DroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL] = []
    func append(_ url: URL) { lock.lock(); defer { lock.unlock() }; values.append(url) }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return values }
}
