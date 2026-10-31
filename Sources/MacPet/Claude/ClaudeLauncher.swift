import AppKit

/// Abre o Claude Code numa aba nova do iTerm (ou do Terminal, se não houver iTerm).
enum ClaudeLauncher {
    static func newSession(in directory: String) {
        run("claude", in: directory)
    }

    static func resume(_ sessionId: String, in directory: String) {
        run("claude --resume \(shellQuote(sessionId))", in: directory)
    }

    static func run(prompt: String, in directory: String) {
        run("claude \(shellQuote(prompt))", in: directory)
    }

    private static func run(_ command: String, in directory: String) {
        let line = "cd \(shellQuote(directory)) && \(command)"
        let usesITerm = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
        let script = usesITerm ? """
            tell application "iTerm2"
                activate
                if (count of windows) = 0 then
                    create window with default profile
                else
                    tell current window to create tab with default profile
                end if
                tell current session of current window to write text "\(appleScriptEscape(line))"
            end tell
            """ : """
            tell application "Terminal"
                activate
                do script "\(appleScriptEscape(line))"
            end tell
            """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { NSLog("MacPet: falha ao abrir o terminal: \(error)") }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private static func appleScriptEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
