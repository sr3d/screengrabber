import AppKit
import Sparkle

/// A small settings window for the save location, filename prefix, and the
/// auto-save-on-capture toggle. Changes are written to `Preferences` live.
final class PreferencesWindowController: NSWindowController {

    private let prefs = Preferences.shared
    private let updater: SPUUpdater?
    private let pathLabel = NSTextField(labelWithString: "")
    private let prefixField = NSTextField(string: "")
    private let previewLabel = NSTextField(labelWithString: "")

    /// Default-tool popup entries, in display order. nil = Select (no tool).
    private let toolItems: [(title: String, tool: Tool?)] =
        [("Select (no tool)", nil)] + Tool.paletteOrder.map { ($0.displayName, $0) }

    init(updater: SPUUpdater?) {
        self.updater = updater
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 410),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ScreenGrabber Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildContent() {
        // Save location row.
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        let choose = NSButton(title: "Choose…", target: self, action: #selector(choose))
        let useDefault = NSButton(title: "Use Default", target: self, action: #selector(useDefault))
        let locationRow = NSStackView(views: [pathLabel, choose, useDefault])
        locationRow.spacing = 8
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Filename row.
        prefixField.target = self
        prefixField.action = #selector(prefixChanged)
        prefixField.placeholderString = "Screenshot"
        prefixField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        previewLabel.font = .systemFont(ofSize: 11)
        previewLabel.textColor = .secondaryLabelColor
        let filenameRow = NSStackView(views: [prefixField, previewLabel])
        filenameRow.spacing = 10

        // Capture-behavior toggles.
        let autoSave = NSButton(checkboxWithTitle: "Save a file automatically when a screenshot is taken",
                                target: self, action: #selector(autoSaveToggled(_:)))
        autoSave.state = prefs.autoSave ? .on : .off

        let copyOnCapture = NSButton(checkboxWithTitle: "Copy screenshot to the clipboard automatically",
                                     target: self, action: #selector(copyOnCaptureToggled(_:)))
        copyOnCapture.state = prefs.copyToClipboardOnCapture ? .on : .off

        let showEditor = NSButton(checkboxWithTitle: "Show the editor after taking a screenshot",
                                  target: self, action: #selector(showEditorToggled(_:)))
        showEditor.state = prefs.showEditorOnCapture ? .on : .off

        // Default drawing tool.
        let toolPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        toolPopup.addItems(withTitles: toolItems.map { $0.title })
        let currentTool = prefs.defaultTool
        toolPopup.selectItem(at: toolItems.firstIndex { $0.tool == currentTool } ?? 0)
        toolPopup.target = self
        toolPopup.action = #selector(defaultToolChanged(_:))
        toolPopup.toolTip = "Tool selected when the editor opens"

        // Startup.
        let startAtLogin = NSButton(checkboxWithTitle: "Start ScreenGrabber at login",
                                    target: self, action: #selector(startAtLoginToggled(_:)))
        startAtLogin.state = prefs.launchAtLogin ? .on : .off

        // Updates. Sparkle owns this setting (stored in its own UserDefaults
        // keys); we just surface its toggle here.
        let autoUpdate = NSButton(checkboxWithTitle: "Check for updates automatically",
                                  target: self, action: #selector(autoUpdateToggled(_:)))
        autoUpdate.state = (updater?.automaticallyChecksForUpdates ?? true) ? .on : .off
        autoUpdate.isEnabled = (updater != nil)

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Save to:"), locationRow],
            [NSTextField(labelWithString: "Filename:"), filenameRow],
            [NSTextField(labelWithString: "On capture:"), autoSave],
            [NSGridCell.emptyContentView, copyOnCapture],
            [NSGridCell.emptyContentView, showEditor],
            [NSTextField(labelWithString: "Default tool:"), toolPopup],
            [NSTextField(labelWithString: "Startup:"), startAtLogin],
            [NSTextField(labelWithString: "Updates:"), autoUpdate],
        ])
        grid.rowSpacing = 16
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])
        window?.contentView = content
    }

    private func refresh() {
        let path = prefs.saveDirectory.path
        pathLabel.stringValue = prefs.usingDefaultDirectory ? "\(path)  (default)" : path
        pathLabel.toolTip = path
        prefixField.stringValue = prefs.filenamePrefix
        previewLabel.stringValue = "e.g. " + prefs.previewFilename()
    }

    // MARK: - Actions

    @objc private func choose() {
        guard let window = window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.saveDirectory
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.prefs.saveDirectoryPath = url.path
            self?.refresh()
        }
    }

    @objc private func useDefault() {
        prefs.saveDirectoryPath = nil
        refresh()
    }

    @objc private func prefixChanged() {
        prefs.filenamePrefix = prefixField.stringValue.trimmingCharacters(in: .whitespaces)
        refresh()
    }

    @objc private func autoSaveToggled(_ sender: NSButton) {
        prefs.autoSave = (sender.state == .on)
    }

    @objc private func copyOnCaptureToggled(_ sender: NSButton) {
        prefs.copyToClipboardOnCapture = (sender.state == .on)
    }

    @objc private func showEditorToggled(_ sender: NSButton) {
        prefs.showEditorOnCapture = (sender.state == .on)
    }

    @objc private func defaultToolChanged(_ sender: NSPopUpButton) {
        prefs.defaultTool = toolItems[sender.indexOfSelectedItem].tool
    }

    @objc private func startAtLoginToggled(_ sender: NSButton) {
        prefs.launchAtLogin = (sender.state == .on)
        // Reflect the real status in case registration was rejected by the system.
        sender.state = prefs.launchAtLogin ? .on : .off
    }

    @objc private func autoUpdateToggled(_ sender: NSButton) {
        updater?.automaticallyChecksForUpdates = (sender.state == .on)
    }
}
