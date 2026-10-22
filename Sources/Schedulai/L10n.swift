import Foundation
import Observation

enum AppLanguage: String, CaseIterable {
    case system
    case english = "en"
    case french = "fr"
}

/// The UI is written in English; `french` translates it. The choice is kept in
/// UserDefaults under `appLanguage` (run-job.sh reads it too, for its
/// notification); `system` follows the first macOS preferred language.
enum L10n {
    static let defaultsKey = "appLanguage"
    /// Named explicitly: run as `schedulai` through its symlink, the binary's
    /// own defaults domain is not the app's.
    static var defaultsDomain: CFString { "com.charlesparis.schedulai" as CFString }

    /// "en" or "fr". Written on the main actor only, read from anywhere.
    nonisolated(unsafe) static var lang = resolve(stored)

    static var stored: AppLanguage {
        let value = CFPreferencesCopyAppValue(defaultsKey as CFString, defaultsDomain) as? String
        return AppLanguage(rawValue: value ?? "") ?? .system
    }

    static func store(_ choice: AppLanguage) {
        CFPreferencesSetAppValue(defaultsKey as CFString, choice.rawValue as CFString, defaultsDomain)
        CFPreferencesAppSynchronize(defaultsDomain)
    }

    static var systemLang: String {
        Locale.preferredLanguages.first?.hasPrefix("fr") == true ? "fr" : "en"
    }

    static func resolve(_ choice: AppLanguage) -> String {
        choice == .system ? systemLang : choice.rawValue
    }

    /// The chosen language with the user's region, for dates.
    static var locale: Locale {
        Locale(identifier: lang + (Locale.current.region.map { "_\($0.identifier)" } ?? ""))
    }

    static func date(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale))
    }

    static func relative(_ date: Date) -> String {
        date.formatted(Date.RelativeFormatStyle(presentation: .named, locale: locale))
    }

    static let french: [String: String] = [
        // Delete
        "Delete \u{201C}%@\u{201D}?": "Supprimer « %@ » ?",
        "Its schedule is removed and its folder — prompt and reports — goes to the Trash.":
            "Sa planification est retirée et son dossier — prompt et comptes rendus — part à la Corbeille.",
        "Move to Trash": "Mettre à la Corbeille",
        "Could not delete the cron: %@": "Impossible de supprimer le cron : %@",
        "Delete…": "Supprimer…",
        "Delete this cron (its folder goes to the Trash)": "Supprimer ce cron (son dossier part à la Corbeille)",
        "Pause": "Mettre en pause",
        "Activate": "Activer",
        // Agents
        "No tool: text answer only": "Aucun outil : réponse texte seulement",
        "Sandbox %@ + network": "Bac à sable %@ + réseau",
        "Sandbox %@": "Bac à sable %@",
        "Approval %@": "Approbation %@",
        "Approval %@ · %@": "Approbation %@ · %@",
        "Unknown agent \"%@\": write claude, codex or gemini.": "Agent inconnu « %@ » : écris claude, codex ou gemini.",
        "sandbox: \"%@\" is not one of %@.": "sandbox : « %@ » ne fait pas partie de %@.",
        "network: write true or false.": "network : écris true ou false.",
        "approval: \"%@\" is not one of %@.": "approval : « %@ » ne fait pas partie de %@.",
        "%@ is not installed": "%@ n'est pas installé",
        "Runs will fail until it is. Click for how to install it.": "Les passages échoueront tant qu'il ne l'est pas. Clique pour savoir comment l'installer.",
        "No AI agent found": "Aucun agent IA trouvé",
        "SchedulAI runs your prompts with Claude Code, Codex or Gemini CLI. Install one of them, then sign in once in a terminal.":
            "SchedulAI lance tes prompts avec Claude Code, Codex ou Gemini CLI. Installe l'un d'eux, puis connecte-toi une fois dans un terminal.",
        // Schedule
        "No `schedule:` line in the frontmatter.": "Pas de ligne `schedule:` dans le frontmatter.",
        "\"%@\": write e.g. `every 30m` or `every 2h`.": "« %@ » : écris par exemple `every 30m` ou `every 2h`.",
        "\"%@\" is not a valid time (HH:MM).": "« %@ » n'est pas une heure valide (HH:MM).",
        "\"%@\" is neither a day nor a time.": "« %@ » n'est ni un jour ni une heure.",
        "\"%@\": a time (HH:MM) is missing.": "« %@ » : il manque une heure (HH:MM).",
        "Every %@ h": "Toutes les %@ h",
        "Every %@ min": "Toutes les %@ min",
        "Every day": "Tous les jours",
        "Weekdays": "Du lundi au vendredi",
        "%@ at %@": "%@ à %@",
        // Runs
        "Never run": "Jamais lancé",
        "Running, started %@": "En cours, lancé %@",
        "OK %@": "OK %@",
        "Failed (%@) %@": "Échec (%@) %@",
        "Interrupted %@": "Interrompu %@",
        " — running": " — en cours",
        " — interrupted": " — interrompu",
        "No log yet.": "Pas encore de log.",
        "Claude is working…": "Claude travaille…",
        "(empty log)": "(log vide)",
        // Store
        "No active cron": "Aucun cron actif",
        "%@ active cron": "%@ cron actif",
        "%@ active crons": "%@ crons actifs",
        "%@ running": "%@ en cours",
        "%@ failed on the last run": "%@ en échec au dernier passage",
        "Next run %@.": "Prochain passage %@.",
        "All good.": "Tout va bien.",
        "Open at login: %@": "Ouverture au démarrage : %@",
        "Invalid schedule.": "Planification invalide.",
        "Could not start the job: %@": "Impossible de lancer le job : %@",
        "Give the cron a name.": "Donne un nom au cron.",
        "A cron \"%@\" already exists.": "Un cron « %@ » existe déjà.",
        "Could not create the cron: %@": "Impossible de créer le cron : %@",
        "Could not change %@: %@": "Impossible de modifier %@ : %@",
        "launchctl bootstrap failed (%@): %@": "launchctl bootstrap a échoué (%@) : %@",
        "Could not write the LaunchAgent: %@": "Impossible d'écrire le LaunchAgent : %@",
        "Could not install run-job.sh: %@": "Impossible d'installer run-job.sh : %@",
        "What this cron does, in one sentence.": "Ce que fait ce cron, en une phrase.",
        "Describe here what the agent should do, then end with a short report.":
            "Décris ici ce que l'agent doit faire, puis termine par un court compte rendu en français.",
        // Menus
        "Crons": "Crons",
        "No crons yet": "Aucun cron pour l'instant",
        "No crons": "Aucun cron",
        "Click to clear": "Cliquer pour effacer",
        "Open at login": "Ouvrir au démarrage du Mac",
        "Approve in Settings › Login Items": "À autoriser dans Réglages › Ouverture",
        "New cron…": "Nouveau cron…",
        "Open SchedulAI…": "Ouvrir SchedulAI…",
        "Quit SchedulAI": "Quitter SchedulAI",
        "Invalid schedule: %@": "Planification invalide : %@",
        "Next run: %@": "Prochain passage : %@",
        "Stop": "Arrêter",
        "Run now": "Lancer maintenant",
        "Open last log": "Ouvrir le dernier log",
        "Edit prompt…": "Modifier le prompt…",
        "Active": "Actif",
        "Inactive": "Inactif",
        "Inactive · %@": "Inactif · %@",
        "Language": "Langue",
        "System (%@)": "Système (%@)",
        // Window
        "New cron": "Nouveau cron",
        "Open the crons folder": "Ouvrir le dossier des crons",
        "No cron selected": "Aucun cron sélectionné",
        "A cron is a folder in ~/.claude/scheduled/ holding a prompt.md.":
            "Un cron est un dossier de ~/.claude/scheduled/ qui contient un prompt.md.",
        "Invalid schedule": "Planification invalide",
        "Cron name": "Nom du cron",
        "Add a description…": "Ajouter une description…",
        "Schedule": "Planification",
        "Next run": "Prochain passage",
        "Working directory": "Dossier de travail",
        "Last run": "Dernier passage",
        "Open folder": "Ouvrir le dossier",
        "View": "Vue",
        "Open in editor": "Ouvrir dans l'éditeur",
        "Discard changes": "Annuler les modifications",
        "Save": "Enregistrer",
        "The frontmatter is missing (name, schedule, workdir… between two --- lines).":
            "Il manque le frontmatter (name, schedule, workdir… entre deux lignes ---).",
        "The prompt is empty below the frontmatter.": "Le prompt est vide sous le frontmatter.",
        "Schedule: %@": "Planification : %@",
        " — not saved (⌘S)": " — non enregistré (⌘S)",
        "Could not save the prompt: %@": "Impossible d'enregistrer le prompt : %@",
        "Name, e.g. \"Morning PR review\"": "Nom, par ex. « Revue des PR du matin »",
        "Creates ~/.claude/scheduled/<name>/prompt.md and opens it in the Prompt tab. Turn it on once the prompt is written.":
            "Crée ~/.claude/scheduled/<nom>/prompt.md et l'ouvre dans l'onglet Prompt. Active-le une fois le prompt écrit.",
        "Failed (%@)": "Échec (%@)",
        "Running": "En cours",
        "Interrupted": "Interrompu",
        "Turn it on to schedule it": "Active-le pour le planifier",
        "Success rate": "Taux de réussite",
        "over %@ runs": "sur %@ passages",
        "Report": "Compte rendu",
        "No runs yet": "Aucun passage pour l'instant",
        "Raw": "Brut",
        "Copy": "Copier",
        "Check for Updates…": "Rechercher des mises à jour…",
        "Version %@": "Version %@",
        "Updates only apply to the copy in /Applications.": "Seule la copie de /Applications se met à jour.",
        "Checking for updates…": "Recherche de mises à jour…",
        "Version %@ · up to date": "Version %@ · à jour",
        "SchedulAI %@ is the latest version.": "SchedulAI %@ est la dernière version.",
        "Version %@ waits for the running cron": "La version %@ attend la fin du cron en cours",
        "Installing SchedulAI %@…": "Installation de SchedulAI %@…",
        "Version %@ · update check failed": "Version %@ · vérification impossible",
        "Could not update: %@": "Mise à jour impossible : %@",
        "no release found on github.com/%@": "aucune release sur github.com/%@",
        "release %@ has no Schedulai.zip": "la release %@ n'a pas de Schedulai.zip",
        "the download does not match its checksum": "le téléchargement ne correspond pas à son empreinte",
        "the archive holds no Schedulai.app": "l'archive ne contient pas Schedulai.app",
        "SchedulAI %@ is installed.": "SchedulAI %@ est installé.",
        "Cancel": "Annuler",
        "Create": "Créer",
    ]
}

/// An English UI string in the chosen language; `%@` placeholders take `args`.
func tr(_ english: String, _ args: String...) -> String {
    let template = L10n.lang == "fr" ? (L10n.french[english] ?? english) : english
    return args.isEmpty ? template : String(format: template, arguments: args)
}

/// The language picker's state; the views key their identity on `resolved`,
/// so switching redraws every string.
@MainActor
@Observable
final class LanguageSettings {
    static let shared = LanguageSettings()

    var choice = L10n.stored {
        didSet {
            L10n.store(choice)
            L10n.lang = L10n.resolve(choice)
            JobStore.shared.reload()
        }
    }

    var resolved: String { L10n.resolve(choice) }

    func title(_ language: AppLanguage) -> String {
        switch language {
        case .system: return tr("System (%@)", L10n.systemLang == "fr" ? "Français" : "English")
        case .english: return "English"
        case .french: return "Français"
        }
    }
}
