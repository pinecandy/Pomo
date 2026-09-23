import AppKit
import Combine
import Foundation

/// Show the update control only when both revisions were read and they differ.
/// A missing stamp, a failed fetch, or an empty string stays hidden.
func updateIsAvailable(installed: String?, remote: String?) -> Bool {
    guard let installed = normalizedRevision(installed),
          let remote = normalizedRevision(remote) else { return false }
    return installed != remote
}

private func normalizedRevision(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// This Mac's checkout. A failed read hides the control.
enum UpdateGit {
    static var repoURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pomo")
    }

    static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Pomo/update-src")
    }

    static func remoteMain(at repo: URL) -> String? {
        guard isCheckout(repo) else { return nil }
        guard git(repo, ["fetch", "origin", "main"]) == 0 else { return nil }
        return gitOutput(repo, ["rev-parse", "origin/main"])
    }

    /// Build `origin/main` in a cache worktree so the dev checkout's branch stays put.
    static func installMain(repo: URL) -> Bool {
        guard remoteMain(at: repo) != nil else { return false }
        guard prepareWorktree(repo: repo, cache: cacheURL) else { return false }
        let script = cacheURL.appendingPathComponent("scripts/deploy.sh")
        return run(executable: script, arguments: [], cwd: cacheURL) == 0
    }

    static func relaunchInstalledApp() {
        let url = URL(fileURLWithPath: "/Applications/Pomo.app")
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            Task { @MainActor in
                if error == nil {
                    NSApp.terminate(nil)
                } else {
                    UpdateCenter.shared.finishInstalling()
                }
            }
        }
    }

    static func readInstalledCommit() -> String? {
        // `url(forResource:withExtension: nil)` does not find an extensionless file.
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("BuildCommit")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return normalizedRevision(text)
    }

    private static func isCheckout(_ repo: URL) -> Bool {
        FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path)
    }

    private static func prepareWorktree(repo: URL, cache: URL) -> Bool {
        let gitEntry = cache.appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: gitEntry.path) {
            return git(cache, ["reset", "--hard", "origin/main"]) == 0
        }
        if FileManager.default.fileExists(atPath: cache.path) { return false }
        try? FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return git(repo, ["worktree", "add", "--detach", cache.path, "origin/main"]) == 0
    }

    private static func git(_ cwd: URL, _ args: [String]) -> Int32 {
        run(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: args, cwd: cwd)
    }

    private static func gitOutput(_ cwd: URL, _ args: [String]) -> String? {
        let pipe = Pipe()
        let status = run(executable: URL(fileURLWithPath: "/usr/bin/git"),
                         arguments: args, cwd: cwd, stdout: pipe)
        guard status == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return normalizedRevision(String(data: data, encoding: .utf8))
    }

    @discardableResult
    private static func run(executable: URL, arguments: [String], cwd: URL,
                            stdout: Pipe? = nil) -> Int32 {
        let process = Process()
        process.currentDirectoryURL = cwd
        process.executableURL = executable
        process.arguments = arguments
        process.environment = commandEnvironment()
        process.standardOutput = stdout ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return 1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func commandEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let prefix = "/opt/homebrew/bin:/usr/local/bin"
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = prefix + ":" + path
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }
}

@MainActor
final class UpdateCenter: ObservableObject {
    static let shared = UpdateCenter()

    @Published private(set) var isAvailable = false
    @Published private(set) var isInstalling = false

    func check() {
        let installed = UpdateGit.readInstalledCommit()
        let repo = UpdateGit.repoURL
        Task.detached {
            let remote = UpdateGit.remoteMain(at: repo)
            let show = updateIsAvailable(installed: installed, remote: remote)
            await MainActor.run {
                UpdateCenter.shared.isAvailable = show
                TimerRegistry.shared.instances.forEach { $0.relayoutWindow() }
            }
        }
    }

    func finishInstalling() {
        isInstalling = false
    }

    func install() {
        guard isAvailable, !isInstalling else { return }
        isInstalling = true
        let repo = UpdateGit.repoURL
        Task.detached {
            let ok = UpdateGit.installMain(repo: repo)
            await MainActor.run {
                if ok {
                    UpdateGit.relaunchInstalledApp()
                } else {
                    UpdateCenter.shared.finishInstalling()
                }
            }
        }
    }
}
