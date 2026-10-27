import AppKit
import ServiceManagement

/// The menu bar icon and its menu. A real NSMenu: macOS draws it
/// with the system's glass, section headers and highlight, which a SwiftUI
/// window panel only imitates.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let store: JobStore
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init(store: JobStore) {
        self.store = store
        super.init()
        statusItem.autosaveName = "Schedulai"
        statusItem.button?.setAccessibilityLabel("SchedulAI")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()
        store.onReload = { [weak self] in self?.refreshIcon() }
    }

    private func refreshIcon() {
        statusItem.button?.image = Icons.menuBar(store.menuBarBadge)
    }

    /// Rebuilt on every open, so it always shows the latest state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        store.reload()
        menu.removeAllItems()

        let header = NSMenuItem()
        header.view = HeaderView(title: store.summary, caption: store.headerCaption)
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: tr("Crons")))
        if store.jobs.isEmpty {
            let empty = NSMenuItem(title: tr("No crons yet"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for job in store.jobs {
            menu.addItem(JobMenu.item(for: job, store: store))
        }
        if let error = store.errorMessage {
            menu.addItem(.separator())
            let item = ClosureMenuItem(error) { [weak self] in self?.store.errorMessage = nil }
            item.image = JobMenu.symbol("exclamationmark.triangle.fill", .systemRed)
            item.toolTip = tr("Click to clear")
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Mac"))
        let login = ClosureMenuItem(tr("Open at login")) { [weak self] in
            guard let self else { return }
            if self.store.loginItemStatus == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else {
                self.store.setLaunchAtLogin(self.store.loginItemStatus != .enabled)
            }
        }
        login.state = store.loginItemStatus == .enabled ? .on : .off
        if store.loginItemStatus == .requiresApproval {
            login.state = .mixed
            login.subtitle = tr("Approve in Settings › Login Items")
        }
        menu.addItem(login)

        let languages = NSMenu()
        let settings = LanguageSettings.shared
        for language in AppLanguage.allCases {
            let item = ClosureMenuItem(settings.title(language)) { settings.choice = language }
            item.state = settings.choice == language ? .on : .off
            languages.addItem(item)
        }
        let languageItem = NSMenuItem(title: tr("Language"), action: nil, keyEquivalent: "")
        languageItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        languageItem.submenu = languages
        menu.addItem(languageItem)

        let updates = ClosureMenuItem(tr("Check for Updates…")) {
            Task { await Updater.shared.check(userInitiated: true) }
        }
        updates.subtitle = Updater.shared.statusLine
        updates.isEnabled = !Updater.shared.isBusy
        updates.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        menu.addItem(updates)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(tr("New cron…"), key: "n") { [weak self] in self?.store.showMainWindow(newJob: true) })
        menu.addItem(ClosureMenuItem(tr("Open SchedulAI…"), key: "o") { [weak self] in self?.store.showMainWindow() })
        menu.addItem(ClosureMenuItem(tr("Quit SchedulAI"), key: "q") { NSApp.terminate(nil) })
    }
}

/// The menu entry of one job, shared by the menu bar menu and the Dock menu.
@MainActor
enum JobMenu {
    static func item(for job: Job, store: JobStore) -> NSMenuItem {
        let item = NSMenuItem(title: job.name, action: nil, keyEquivalent: "")
        item.image = statusImage(job)
        item.subtitle = job.enabled ? job.lastRunText : tr("Inactive · %@", job.lastRunText)
        item.toolTip = job.about

        let submenu = NSMenu()
        info(job.triggerSummary(names: store.jobNames), to: submenu)
        if job.enabled, let next = job.schedule?.nextRun(after: .now) {
            info(tr("Next run: %@", L10n.date(next)), to: submenu)
        }
        submenu.addItem(.separator())
        if job.state == .running {
            submenu.addItem(ClosureMenuItem(tr("Stop")) { store.stop(job) })
        } else {
            submenu.addItem(ClosureMenuItem(tr("Run now")) { store.runNow(job) })
        }
        if let log = job.logs.first {
            submenu.addItem(ClosureMenuItem(tr("Open last log")) { NSWorkspace.shared.open(log) })
        }
        submenu.addItem(ClosureMenuItem(tr("Edit prompt…")) { store.showMainWindow(job: job.id, editPrompt: true) })
        submenu.addItem(ClosureMenuItem(tr("Challenge with AI")) {
            Session.start(job, agent: store.sessionAgent(for: job), note: nil, focus: job.logs.first,
                          resume: Session.resumableRun(job, log: job.logs.first), store: store)
        })
        submenu.addItem(.separator())
        let toggle = ClosureMenuItem(tr("Active")) { store.setEnabled(job, !job.enabled) }
        toggle.state = job.enabled ? .on : .off
        submenu.addItem(toggle)
        submenu.addItem(.separator())
        submenu.addItem(ClosureMenuItem(tr("Delete…")) { store.askToDelete(job) })
        item.submenu = submenu
        return item
    }

    static func symbol(_ name: String, _ color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
    }

    private static func statusImage(_ job: Job) -> NSImage? {
        switch job.state {
        case .running: return symbol("arrow.triangle.2.circlepath.circle.fill", .systemBlue)
        case .failed: return symbol("xmark.circle.fill", .systemRed)
        case .succeeded: return job.enabled ? symbol("checkmark.circle.fill", .systemGreen) : symbol("pause.circle", .secondaryLabelColor)
        case .never: return job.enabled ? symbol("clock", .secondaryLabelColor) : symbol("pause.circle", .secondaryLabelColor)
        }
    }

    private static func info(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }
}

/// The menu's top: a title and a caption, in AppKit views so they
/// lay out inside an NSMenuItem.
private final class HeaderView: NSView {
    private static let width: CGFloat = 280

    init(title: String, caption: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 44))
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let captionLabel = NSTextField(wrappingLabelWithString: caption)
        captionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.preferredMaxLayoutWidth = Self.width - 28

        let stack = NSStackView(views: [titleLabel, captionLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 4, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        layoutSubtreeIfNeeded()
        setFrameSize(NSSize(width: Self.width, height: fittingSize.height))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}
