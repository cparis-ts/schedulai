import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: JobStore
    @State private var selection: Job.ID?
    @State private var showingNewJob = false
    @Environment(\.openWindow) private var openWindow
    @Bindable private var language = LanguageSettings.shared

    var body: some View {
        NavigationSplitView {
            Sidebar(store: store, selection: $selection)
                .navigationSplitViewColumnWidth(min: 270, ideal: 300)
                .toolbar {
                    ToolbarItemGroup {
                        Button {
                            showingNewJob = true
                        } label: {
                            Label(tr("New cron"), systemImage: "plus")
                        }
                        Button {
                            NSWorkspace.shared.open(store.root)
                        } label: {
                            Label(tr("Open the crons folder"), systemImage: "folder")
                        }
                        Menu {
                            Picker(tr("Language"), selection: $language.choice) {
                                ForEach(AppLanguage.allCases, id: \.self) { choice in
                                    Text(language.title(choice)).tag(choice)
                                }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Label(tr("Language"), systemImage: "globe")
                        }
                    }
                }
        } detail: {
            ZStack {
                Backdrop()
                if let job = store.jobs.first(where: { $0.id == selection }) {
                    JobDetail(store: store, job: job)
                        .id(job.id)
                } else {
                    ContentUnavailableView(
                        tr("No cron selected"),
                        systemImage: "clock.badge.questionmark",
                        description: Text(tr("A cron is a folder in ~/.claude/scheduled/ holding a prompt.md."))
                    )
                }
            }
        }
        .toolbar(removing: .title)
        // Every string is looked up at render time: a new language redraws them all.
        .id(language.resolved)
        .onAppear {
            if selection == nil { selection = store.jobs.first?.id }
            store.openWindow = { openWindow(id: "main") }
            if ProcessInfo.processInfo.environment["SCHEDULAI_TOUR"] != nil {
                Task { await tour() }
            }
        }
        .onChange(of: store.requestedJob) { _, id in
            if let id {
                selection = id
                store.requestedJob = nil
            }
        }
        .onChange(of: store.newJobRequested) { _, requested in
            if requested {
                showingNewJob = true
                store.newJobRequested = false
            }
        }
        .sheet(isPresented: $showingNewJob) {
            NewJobSheet { name in
                if let id = store.createJob(named: name) {
                    selection = id
                    store.requestedPromptTab = true
                }
            }
        }
        .alert("Schedulai", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

extension ContentView {
    /// `SCHEDULAI_TOUR=1`: walks through the jobs on its own, for recording
    /// the README's animation. Writes "tour-start" and "tour-done" to stderr.
    @MainActor
    func tour() async {
        try? await Task.sleep(for: .seconds(1))
        NSApp.windows.first { $0.canBecomeMain }?.setFrame(NSRect(x: 80, y: 80, width: 1240, height: 780), display: true)
        let ids = store.jobs.map(\.id)
        func show(_ id: String, prompt: Bool = false, for seconds: Double) async {
            selection = id
            if prompt { store.requestedPromptTab = true }
            try? await Task.sleep(for: .seconds(seconds))
        }
        guard ids.count >= 4 else { return }
        FileHandle.standardError.write(Data("tour-start\n".utf8))
        await show(ids[2], for: 3.5)            // Morning PR digest: its report
        await show(ids[2], prompt: true, for: 3) // …and its prompt
        await show(ids[0], for: 3)              // Dependency audit: a failed run
        await show(ids[1], for: 2.5)            // Inbox triage: running
        await show(ids[3], for: 2.5)            // Release notes: paused
        await show(ids[2], for: 2)
        FileHandle.standardError.write(Data("tour-done\n".utf8))
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    let store: JobStore
    @Binding var selection: Job.ID?

    var body: some View {
        List(selection: $selection) {
            ForEach(store.jobs) { job in
                JobRow(job: job)
                    .tag(job.id)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Schedulai \(Updater.shared.currentVersion)").font(.headline)
                    Text(store.summary + " · " + store.headerCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .padding(10)
        }
    }
}

private struct JobRow: View {
    let job: Job

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            StatusBadge(job: job, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(job.enabled ? .primary : .secondary)
                if let about = job.about {
                    Text(about)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Label(job.enabled ? (job.schedule?.summary ?? tr("Invalid schedule")) : tr("Inactive"),
                          systemImage: job.enabled ? "calendar" : "pause")
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let run = job.history.first {
                        Text(L10n.relative(run.startedAt))
                            .foregroundStyle(job.state == .failed ? .red : .secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Detail

private struct JobDetail: View {
    let store: JobStore
    let job: Job
    @State private var tab = Tab.log
    @State private var selectedLog: URL?
    @State private var rawLog = false
    @State private var nameDraft = ""
    @State private var aboutDraft = ""
    @FocusState private var focus: MetaField?
    /// What the editor shows, and the file's text it started from.
    @State private var draft = ""
    @State private var savedText = ""

    enum MetaField {
        case name, about
    }

    enum Tab {
        case log, prompt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            hero
            stats
            actionBar
            switch tab {
            case .log: logCard
            case .prompt: promptCard
            }
        }
        .padding(22)
        .onAppear {
            draft = diskText
            savedText = diskText
            nameDraft = job.name
            aboutDraft = job.about ?? ""
            takePromptTabRequest()
        }
        .onChange(of: focus) { old, _ in
            // Leaving a field saves it, as Return does.
            if let old { commit(old) }
        }
        .onChange(of: job.name) { _, name in
            if focus != .name { nameDraft = name }
        }
        .onChange(of: job.about) { _, about in
            if focus != .about { aboutDraft = about ?? "" }
        }
        .onChange(of: store.requestedPromptTab) { takePromptTabRequest() }
        .onChange(of: diskText) { _, newText in
            // Changed outside the app: follow it, unless there are edits to keep.
            if !isDirty { draft = newText }
            savedText = newText
        }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 16) {
            StatusBadge(job: job, size: 54)
            VStack(alignment: .leading, spacing: 6) {
                TextField(tr("Cron name"), text: $nameDraft)
                    .font(.title.bold())
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .name)
                    .onSubmit { commit(.name) }
                TextField(tr("Add a description…"), text: $aboutDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.secondary)
                    .lineLimit(1...3)
                    .focused($focus, equals: .about)
                    .onSubmit { commit(.about) }
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        if let error = job.scheduleError {
                            Pill(systemImage: "exclamationmark.triangle.fill", text: error, tint: .red)
                        } else if let schedule = job.schedule {
                            Pill(systemImage: "calendar", text: schedule.summary, tint: .brand)
                        }
                        Pill(systemImage: "folder", text: job.workdir)
                        if let model = job.model {
                            Pill(systemImage: "cpu", text: model)
                        }
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 12) {
                Toggle(tr("Active"), isOn: Binding(
                    get: { job.enabled },
                    set: { store.setEnabled(job, $0) }
                ))
                .toggleStyle(.switch)
                .tint(.brand)
                if !job.history.isEmpty {
                    RunDots(runs: job.history)
                }
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    // MARK: Stats

    private var stats: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                if let next = job.enabled ? job.schedule?.nextRun(after: .now) : nil {
                    StatTile(title: tr("Next run"), systemImage: "clock", value: L10n.relative(next), detail: L10n.date(next))
                } else {
                    StatTile(title: tr("Next run"), systemImage: "clock",
                             value: job.enabled ? (job.schedule?.summary ?? "—") : tr("Inactive"),
                             detail: job.enabled ? "" : tr("Turn it on to schedule it"))
                }
                if let run = job.history.first {
                    StatTile(title: tr("Last run"), systemImage: RunFormat.symbol(run),
                             value: RunFormat.outcome(run),
                             detail: [L10n.relative(run.startedAt), RunFormat.duration(run)].compactMap { $0 }.joined(separator: " · "),
                             tint: run.exitCode == 0 ? .green : run.exitCode == nil ? .blue : .red)
                } else {
                    StatTile(title: tr("Last run"), systemImage: "circle.dashed", value: tr("Never run"), detail: "")
                }
                let finished = job.history.filter { $0.exitCode != nil }
                StatTile(title: tr("Success rate"), systemImage: "chart.bar.fill",
                         value: finished.isEmpty ? "—" : "\(finished.filter { $0.exitCode == 0 }.count * 100 / finished.count) %",
                         detail: tr("over %@ runs", "\(finished.count)"))
            }
        }
    }

    // MARK: Actions

    private var actionBar: some View {
        HStack(spacing: 10) {
            if job.state == .running {
                Button(tr("Stop"), systemImage: "stop.fill") { store.stop(job) }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
            } else {
                Button(tr("Run now"), systemImage: "play.fill") { store.runNow(job) }
                    .buttonStyle(.glassProminent)
                    .tint(.brand)
            }
            Button(tr("Open folder"), systemImage: "folder") { NSWorkspace.shared.open(job.dir) }
                .buttonStyle(.glass)
            Spacer()
            Picker(tr("View"), selection: $tab) {
                Label(tr("Report"), systemImage: "doc.richtext").tag(Tab.log)
                Label(isDirty ? "Prompt •" : "Prompt", systemImage: "text.cursor").tag(Tab.prompt)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .tint(.brand)
        }
        .controlSize(.large)
    }

    // MARK: Report

    private var logEntries: [(url: URL, run: RunStatus?)] {
        var seen = Set<String>()
        var entries: [(URL, RunStatus?)] = []
        for run in job.history {
            guard let name = run.log, !seen.contains(name) else { continue }
            let url = job.dir.appending(path: "logs/\(name)")
            if FileManager.default.fileExists(atPath: url.path) {
                entries.append((url, run))
                seen.insert(name)
            }
        }
        for url in job.logs where !seen.contains(url.lastPathComponent) {
            entries.append((url, nil))
        }
        return entries
    }

    private var logCard: some View {
        let entries = logEntries
        let current = selectedLog ?? entries.first?.url
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if entries.isEmpty {
                    Label(tr("No runs yet"), systemImage: "tray")
                        .foregroundStyle(.secondary)
                } else {
                    Menu {
                        ForEach(entries, id: \.url) { entry in
                            Button {
                                selectedLog = entry.url
                            } label: {
                                Label(entry.run.map(RunFormat.line) ?? entry.url.deletingPathExtension().lastPathComponent,
                                      systemImage: RunFormat.symbol(entry.run))
                            }
                        }
                    } label: {
                        let run = entries.first { $0.url == current }?.run
                        Label(run.map(RunFormat.line) ?? current?.deletingPathExtension().lastPathComponent ?? "",
                              systemImage: RunFormat.symbol(run))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .fixedSize()
                }
                Spacer()
                Toggle(isOn: $rawLog) {
                    Label(tr("Raw"), systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .toggleStyle(.button)
                .buttonStyle(.glass)
                Button(tr("Copy"), systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText(current), forType: .string)
                }
                .buttonStyle(.glass)
                .labelStyle(.iconOnly)
            }
            .padding(12)

            ScrollView {
                let text = logText(current)
                Group {
                    if rawLog {
                        Text(text)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        MarkdownView(text: text)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func logText(_ url: URL?) -> String {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else {
            return tr("No log yet.")
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let limit: UInt64 = 300_000
        try? handle.seek(toOffset: size > limit ? size - limit : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        if text.isEmpty { return job.state == .running ? tr("Claude is working…") : tr("(empty log)") }
        return text
    }

    // MARK: Prompt

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $draft)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(14)
                .frame(maxHeight: .infinity)
            HStack(alignment: .center, spacing: 8) {
                Label(draftCheck.message, systemImage: draftCheck.ok ? "checkmark.seal" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(draftCheck.ok ? Color.secondary : Color.red)
                Spacer()
                Button(tr("Open in editor")) { NSWorkspace.shared.open(job.promptURL) }
                    .buttonStyle(.glass)
                Button(tr("Discard changes")) { draft = savedText }
                    .buttonStyle(.glass)
                    .disabled(!isDirty)
                Button(tr("Save")) { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.glassProminent)
                    .tint(.brand)
                    .disabled(!isDirty)
            }
            .padding([.horizontal, .bottom], 14)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var diskText: String {
        (try? String(contentsOf: job.promptURL, encoding: .utf8)) ?? ""
    }

    private var isDirty: Bool { draft != savedText }

    /// The draft as the runner would read it: frontmatter present, schedule valid, a prompt.
    private var draftCheck: (ok: Bool, message: String) {
        let prompt = PromptFile.parse(draft)
        if prompt.meta.isEmpty {
            return (false, tr("The frontmatter is missing (name, schedule, workdir… between two --- lines)."))
        }
        if prompt.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (false, tr("The prompt is empty below the frontmatter."))
        }
        do {
            let schedule = try Schedule.parse(prompt.meta["schedule"] ?? "")
            return (true, tr("Schedule: %@", schedule.summary) + (isDirty ? tr(" — not saved (⌘S)") : ""))
        } catch let error as ScheduleError {
            return (false, error.message)
        } catch {
            return (false, "\(error)")
        }
    }

    private func save() {
        do {
            try draft.write(to: job.promptURL, atomically: true, encoding: .utf8)
            savedText = draft
            // An active job's new schedule reaches launchd on this reload.
            store.reload()
        } catch {
            store.errorMessage = tr("Could not save the prompt: %@", error.localizedDescription)
        }
    }

    /// Saves the name or description field to the frontmatter, and into an
    /// unsaved prompt draft too, so saving the draft later does not undo it.
    private func commit(_ field: MetaField) {
        let key: String
        let value: String?
        switch field {
        case .name:
            let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                nameDraft = job.name
                return
            }
            guard trimmed != job.name else { return }
            (key, value) = ("name", trimmed)
        case .about:
            let trimmed = aboutDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != (job.about ?? "") else { return }
            (key, value) = ("description", trimmed.isEmpty ? nil : trimmed)
        }
        let wasDirty = isDirty
        store.setMeta(key, value, of: job)
        if wasDirty { draft = PromptFile.setting(key, to: value, in: draft) }
    }

    private func takePromptTabRequest() {
        guard store.requestedPromptTab else { return }
        tab = .prompt
        store.requestedPromptTab = false
    }
}

private struct StatTile: View {
    let title: String
    let systemImage: String
    let value: String
    let detail: String
    var tint: Color = .brand

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail.isEmpty ? " " : detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

// MARK: - New job

private struct NewJobSheet: View {
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                Text(tr("New cron")).font(.title2.bold())
            }
            TextField(tr("Name, e.g. \"Morning PR review\""), text: $name)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(10)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .onSubmit(create)
            Text(tr("Creates ~/.claude/scheduled/<name>/prompt.md and opens it in the Prompt tab. Turn it on once the prompt is written."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr("Cancel"), role: .cancel) { dismiss() }
                    .buttonStyle(.glass)
                Button(tr("Create"), action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .tint(.brand)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: 420)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        dismiss()
        onCreate(trimmed)
    }
}
