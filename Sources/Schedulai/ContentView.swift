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
        .onChange(of: store.jobs.map(\.id)) { _, ids in
            if let current = selection, !ids.contains(current) { selection = ids.first }
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
        .alert("SchedulAI", isPresented: Binding(
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
                JobRow(job: job, names: store.jobNames)
                    .tag(job.id)
            }
        }
        .contextMenu(forSelectionType: Job.ID.self) { ids in
            if let job = store.jobs.first(where: { ids.contains($0.id) }) {
                Button(tr("Run now"), systemImage: "play") { store.runNow(job) }
                Button(job.enabled ? tr("Pause") : tr("Activate"), systemImage: job.enabled ? "pause" : "checkmark") {
                    store.setEnabled(job, !job.enabled)
                }
                Button(tr("Open folder"), systemImage: "folder") { NSWorkspace.shared.open(job.dir) }
                Button(tr("Challenge with AI"), systemImage: "bubble.left.and.text.bubble.right") {
                    Session.start(job, agent: store.sessionAgent(for: job), note: nil, focus: job.logs.first,
                          resume: Session.resumableRun(job, log: job.logs.first), store: store)
                }
                Divider()
                Button(tr("Delete…"), systemImage: "trash", role: .destructive) { store.askToDelete(job) }
            }
        }
        .onDeleteCommand {
            if let job = store.jobs.first(where: { $0.id == selection }) { store.askToDelete(job) }
        }
        .safeAreaInset(edge: .top) {
            if store.installedAgents.isEmpty {
                NoAgentBanner()
                    .padding(10)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SchedulAI \(Updater.shared.currentVersion)").font(.headline)
                    Text([store.summary, store.headerCaption, store.monthCost > 0 ? tr("%@ this month", RunFormat.cost(store.monthCost)) : nil]
                        .compactMap { $0 }.joined(separator: " · "))
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

/// Shown while no agent command is found: every run would fail.
private struct NoAgentBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(tr("No AI agent found"), systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(tr("SchedulAI runs your prompts with Claude Code, Codex or Gemini CLI. Install one of them, then sign in once in a terminal."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(Agent.allCases, id: \.self) { agent in
                    Button(agent.displayName) { NSWorkspace.shared.open(agent.installURL) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

private struct JobRow: View {
    let job: Job
    let names: [String: String]

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
                    Label(job.enabled ? job.triggerSummary(names: names) : tr("Inactive"),
                          systemImage: !job.enabled ? "pause" : job.schedule != nil ? "calendar"
                            : !job.triggers.after.isEmpty ? "arrow.turn.down.right" : job.triggers.watch.isEmpty ? "person.crop.circle" : "eye")
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
    @State private var showingChallenge = false
    @State private var restoreCandidate: PromptHistory.Version?

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
                        ForEach(job.triggers.after, id: \.self) { other in
                            if let name = store.jobNames[other] {
                                Pill(systemImage: "arrow.turn.down.right", text: tr("after %@", name), tint: .brand)
                                    .help(tr("Runs when \u{201C}%@\u{201D} succeeds", name))
                            } else {
                                Pill(systemImage: "exclamationmark.triangle.fill", text: tr("after: no job \"%@\".", other), tint: .red)
                            }
                        }
                        if !job.triggers.watch.isEmpty {
                            Pill(systemImage: "eye", text: job.triggers.watch.joined(separator: ", "), tint: .brand)
                                .help(tr("Runs when one of these paths changes"))
                        }
                        if job.triggers.atLogin {
                            Pill(systemImage: "person.crop.circle", text: tr("at login"), tint: .brand)
                        }
                        if let agentError = job.agentError {
                            Pill(systemImage: "exclamationmark.triangle.fill", text: agentError, tint: .red)
                        } else if !store.isInstalled(job.agent) {
                            Button {
                                NSWorkspace.shared.open(job.agent.installURL)
                            } label: {
                                Pill(systemImage: "exclamationmark.triangle.fill",
                                     text: tr("%@ is not installed", job.agent.displayName), tint: .red)
                            }
                            .buttonStyle(.plain)
                            .help(tr("Runs will fail until it is. Click for how to install it."))
                        } else {
                            Pill(systemImage: "sparkles", text: job.agent.displayName)
                                .help(job.agent.permissions(job.meta))
                        }
                        Pill(systemImage: "folder", text: job.workdir)
                        if let model = job.model {
                            Pill(systemImage: "cpu", text: model)
                        }
                        if let timeout = job.meta["timeout"], !timeout.isEmpty {
                            Pill(systemImage: "hourglass", text: timeout)
                                .help(tr("A run is stopped after %@", timeout))
                        }
                        if let budget = RunKeys.budget(job.meta["budget"]) {
                            Pill(systemImage: "dollarsign.circle", text: tr("%@ / 24 h", RunFormat.cost(budget)))
                                .help(tr("Runs are skipped once the last 24 hours cost this much"))
                        }
                        if let notify = job.meta["notify"], !notify.isEmpty, notify != "always" {
                            Pill(systemImage: notify == "never" ? "bell.slash" : "bell.badge", text: notify)
                                .help(tr("Notifications: %@", notify))
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
                Toggle(tr("No guardrails"), isOn: Binding(
                    get: { job.agent.isUnrestricted(job.meta) },
                    set: { $0 ? store.askToUnrestrict(job) : store.setUnrestricted(job, false) }
                ))
                .toggleStyle(.switch)
                .tint(.orange)
                .help(tr("On: the agent approves every call and runs outside its sandbox. Off: only the permissions written in prompt.md."))
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
                             value: job.enabled ? job.triggerSummary(names: store.jobNames) : tr("Inactive"),
                             detail: job.enabled ? "" : tr("Turn it on to schedule it"))
                }
                if let run = job.history.first {
                    StatTile(title: tr("Last run"), systemImage: RunFormat.symbol(run),
                             value: RunFormat.outcome(run),
                             detail: [L10n.relative(run.startedAt), RunFormat.duration(run),
                                      run.denied.flatMap { $0 > 0 ? tr("%@ refused", "\($0)") : nil }]
                                 .compactMap { $0 }.joined(separator: " · "),
                             tint: run.skipped != nil ? .orange : run.exitCode == 0 ? .green : run.exitCode == nil ? .blue : .red)
                } else {
                    StatTile(title: tr("Last run"), systemImage: "circle.dashed", value: tr("Never run"), detail: "")
                }
                let finished = job.history.filter { $0.exitCode != nil }
                StatTile(title: tr("Success rate"), systemImage: "chart.bar.fill",
                         value: finished.isEmpty ? "—" : "\(finished.filter { $0.exitCode == 0 }.count * 100 / finished.count) %",
                         detail: tr("over %@ runs", "\(finished.count)"))
                if job.history.contains(where: { $0.costUSD != nil }) {
                    let monthAgo = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
                    let last = job.history.first { $0.costUSD != nil }
                    StatTile(title: tr("Cost"), systemImage: "dollarsign.circle",
                             value: RunFormat.cost(job.cost(since: monthAgo)),
                             detail: tr("30 days") + (last.map { " · " + tr("last run %@", [RunFormat.cost($0.costUSD ?? 0), RunFormat.tokens($0)].compactMap { $0 }.joined(separator: ", ")) } ?? ""))
                }
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
            Button(tr("Challenge with AI…"), systemImage: "bubble.left.and.text.bubble.right") { showingChallenge = true }
                .buttonStyle(.glass)
                .help(tr("Open an AI session that knows this cron: its schedule, permissions, last runs and reports, and its prompt"))
                .sheet(isPresented: $showingChallenge) {
                    ChallengeSheet(store: store, job: job, focus: tab == .log ? selectedLog ?? job.logs.first : nil)
                }
            Button(tr("Delete…"), systemImage: "trash", role: .destructive) { store.askToDelete(job) }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .help(tr("Delete this cron (its folder goes to the Trash)"))
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
                let versions = PromptHistory.versions(job)
                if versions.count > 1 {
                    Menu(tr("Versions")) {
                        ForEach(versions.dropFirst()) { version in
                            Button("\(L10n.date(version.date)) — \(version.message) (\(version.rev))") {
                                restoreCandidate = version
                            }
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .fixedSize()
                    .help(tr("Every saved prompt.md, newest first; each run names the version it ran"))
                }
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
        .confirmationDialog(tr("Restore this version of prompt.md?"), isPresented: Binding(
            get: { restoreCandidate != nil },
            set: { if !$0 { restoreCandidate = nil } }
        ), presenting: restoreCandidate) { version in
            Button(tr("Restore")) {
                store.restore(job, to: version)
                draft = diskText
                savedText = draft
            }
            Button(tr("Cancel"), role: .cancel) {}
        } message: { version in
            Text(tr("The version of %@ (%@) becomes the current prompt. The current one stays in the history.", L10n.date(version.date), version.rev))
        }
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
        let agent = Agent.parse(prompt.meta)
        if let error = agent.error {
            return (false, error)
        }
        if let problem = agent.agent.problems(prompt.meta).first {
            return (false, problem)
        }
        if let problem = RunKeys.problems(prompt.meta, id: job.id, jobIDs: Set(store.jobs.map(\.id))).first {
            return (false, problem)
        }
        let triggers = Triggers(prompt.meta)
        let scheduleText = prompt.meta["schedule"] ?? ""
        let unsaved = isDirty ? tr(" — not saved (⌘S)") : ""
        if scheduleText.trimmingCharacters(in: .whitespaces).isEmpty, !triggers.isEmpty {
            return (true, triggers.summary(names: store.jobNames).capitalizedFirstLetter + unsaved)
        }
        do {
            let schedule = try Schedule.parse(scheduleText)
            return (true, tr("Schedule: %@", schedule.summary) + (triggers.isEmpty ? "" : " · " + triggers.summary(names: store.jobNames)) + unsaved)
        } catch let error as ScheduleError {
            return (false, error.message)
        } catch {
            return (false, "\(error)")
        }
    }

    private func save() {
        do {
            try store.savePrompt(draft, of: job)
            savedText = draft
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

/// "Challenge with AI": what went wrong (optional), which agent, then a
/// session in the terminal — or its command, for a terminal of your own.
private struct ChallengeSheet: View {
    let store: JobStore
    let job: Job
    let focus: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var agent: Agent = .claude
    @State private var copied = false
    @State private var resume = true

    /// The run this session would continue, when it is a Claude run with its session.
    private var resumable: RunStatus? { agent == .claude ? Session.resumableRun(job, log: focus) : nil }
    private var resumed: RunStatus? { resume ? resumable : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.title)
                    .foregroundStyle(Color.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Challenge with AI")).font(.title2.bold())
                    Text(job.name).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Text(tr("The session starts knowing this cron: its schedule, permissions, last runs and reports, and its prompt. It can fix prompt.md with you, check it and test it."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(tr("What went wrong? e.g. \"card TSK-123 was not moved\" (optional)"), text: $note, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...5)
                .padding(10)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
            if let focus {
                Label(tr("Report quoted first: %@", focus.lastPathComponent), systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let run = resumable {
                Toggle(isOn: $resume) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Continue the run's own session"))
                        Text(tr("The agent that ran it on %@ answers, with all it saw and did. Off: a new session, given the brief.", L10n.date(run.startedAt)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .tint(.brand)
            }
            Picker(tr("Agent"), selection: $agent) {
                ForEach(Agent.allCases, id: \.self) { agent in
                    Text(store.isInstalled(agent) ? agent.displayName : tr("%@ (not installed)", agent.displayName))
                        .tag(agent)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            HStack {
                Button(copied ? tr("Copied") : tr("Copy the command"), systemImage: copied ? "checkmark" : "doc.on.doc") {
                    if let command = Session.start(job, agent: agent, note: note, focus: focus, resume: resumed, store: store, open: false) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                    }
                }
                .buttonStyle(.glass)
                .help(tr("For a terminal of your own: paste it there"))
                Spacer()
                Button(tr("Cancel"), role: .cancel) { dismiss() }
                    .buttonStyle(.glass)
                Button(tr("Open the session")) {
                    dismiss()
                    Session.start(job, agent: agent, note: note, focus: focus, resume: resumed, store: store)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .tint(.brand)
                .disabled(!store.isInstalled(agent))
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: 500)
        .onAppear { agent = store.sessionAgent(for: job) }
    }
}

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
