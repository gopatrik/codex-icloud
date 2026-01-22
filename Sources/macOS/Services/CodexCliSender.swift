import Foundation

enum CodexCliSender {
    enum SendError: LocalizedError {
        case notAvailable
        case failed(exitCode: Int32, stderr: String)
        case missingNode

        var errorDescription: String? {
            switch self {
            case .notAvailable:
                return "Codex CLI not available."
            case .failed(let exitCode, let stderr):
                if stderr.isEmpty {
                    return "Codex CLI failed with code \(exitCode)."
                }
                return "Codex CLI failed (\(exitCode)): \(stderr)"
            case .missingNode:
                return "Codex CLI requires Node.js. Set CODEX_NODE_PATH or install node."
            }
        }
    }

    static func send(sessionId: String, text: String, cwd: String) -> Result<Void, Error> {
        #if os(macOS)
        let env = mergedEnvironment()
        let payload = text.hasSuffix("\n") ? text : text + "\n"
        let workingDirectory = cwd.trimmingCharacters(in: .whitespacesAndNewlines)

        if let codexURL = resolveExecutableURL() {
            debugLog("attempting codex at \(codexURL.path)")
            let arguments = codexArguments(sessionId: sessionId, cwd: workingDirectory, skipRepoCheck: false)
            let result = runProcess(
                executableURL: codexURL,
                arguments: arguments,
                environment: env,
                inputText: payload
            )
            if result.status == 0 {
                return .success(())
            }

            let trimmed = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("env: node: No such file or directory") {
                if let nodeURL = resolveNodeURL() {
                    debugLog("retrying with node \(nodeURL.path) and script \(codexURL.path)")
                    let nodeArgs = [codexURL.path] + codexArguments(sessionId: sessionId, cwd: workingDirectory, skipRepoCheck: false)
                    let retry = runProcess(
                        executableURL: nodeURL,
                        arguments: nodeArgs,
                        environment: env,
                        inputText: payload
                    )
                    if retry.status == 0 {
                        return .success(())
                    }
                    let retryTrimmed = retry.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    if retryTrimmed.contains("Not inside a trusted directory") {
                        let skipArgs = [codexURL.path] + codexArguments(sessionId: sessionId, cwd: workingDirectory, skipRepoCheck: true)
                        let skipRetry = runProcess(
                            executableURL: nodeURL,
                            arguments: skipArgs,
                            environment: env,
                            inputText: payload
                        )
                        if skipRetry.status == 0 {
                            return .success(())
                        }
                        return .failure(SendError.failed(exitCode: skipRetry.status, stderr: skipRetry.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                    return .failure(SendError.failed(exitCode: retry.status, stderr: retryTrimmed))
                }
                return .failure(SendError.missingNode)
            }

            if trimmed.contains("Not inside a trusted directory") {
                let retryArgs = codexArguments(sessionId: sessionId, cwd: workingDirectory, skipRepoCheck: true)
                let retry = runProcess(
                    executableURL: codexURL,
                    arguments: retryArgs,
                    environment: env,
                    inputText: payload
                )
                if retry.status == 0 {
                    return .success(())
                }
                return .failure(SendError.failed(exitCode: retry.status, stderr: retry.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
            }

            return .failure(SendError.failed(exitCode: result.status, stderr: trimmed))
        }

        // Fallback to a login shell so PATH from the user's environment is applied.
        debugLog("falling back to shell invocation")
        let shellCommand: String
        if workingDirectory.isEmpty {
            shellCommand = "codex exec resume \(sessionId) -"
        } else {
            shellCommand = "codex -C \(workingDirectory) exec resume \(sessionId) -"
        }
        let shellResult = runProcess(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-lc", shellCommand],
            environment: env,
            inputText: payload
        )
        if shellResult.status == 0 {
            return .success(())
        }
        return .failure(SendError.failed(exitCode: shellResult.status, stderr: shellResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
        #else
        return .failure(SendError.notAvailable)
        #endif
    }

    #if os(macOS)
    private static func mergedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/homebrew/opt/node/bin",
            "\(NSHomeDirectory())/.cargo/bin",
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/bin"
        ]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let merged = (extraPaths + currentPath.split(separator: ":").map(String.init))
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, path in
                if !result.contains(path) { result.append(path) }
            }
        env["PATH"] = merged.joined(separator: ":")
        debugLog("PATH=\(env["PATH"] ?? "")")
        return env
    }

    private static func resolveExecutableURL() -> URL? {
        if let explicit = ProcessInfo.processInfo.environment["CODEX_CLI_PATH"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }

        var candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex",
            "\(NSHomeDirectory())/bin/codex",
            "\(NSHomeDirectory())/.local/bin/codex",
            "\(NSHomeDirectory())/.cargo/bin/codex"
        ]

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            let paths = pathEnv.split(separator: ":").map(String.init)
            for path in paths {
                candidates.append("\(path)/codex")
            }
        }

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    private static func resolveNodeURL() -> URL? {
        if let explicit = ProcessInfo.processInfo.environment["CODEX_NODE_PATH"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }

        var candidates = [
            "/opt/homebrew/bin/node",
            "/opt/homebrew/opt/node/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]

        if let pathEnv = mergedEnvironment()["PATH"] {
            let paths = pathEnv.split(separator: ":").map(String.init)
            for path in paths {
                candidates.append("\(path)/node")
            }
        }

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        if let nvmURL = resolveNvmNodeURL() {
            return nvmURL
        }

        return nil
    }

    private static func resolveNvmNodeURL() -> URL? {
        let nvmRoot = URL(fileURLWithPath: "\(NSHomeDirectory())/.nvm/versions/node", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: nvmRoot, includingPropertiesForKeys: nil) else {
            return nil
        }
        let sorted = entries.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for entry in sorted {
            let candidate = entry.appendingPathComponent("bin/node")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func codexArguments(sessionId: String, cwd: String, skipRepoCheck: Bool) -> [String] {
        var args: [String] = []
        if !cwd.isEmpty {
            args.append(contentsOf: ["-C", cwd])
        }
        args.append("exec")
        if skipRepoCheck {
            args.append("--skip-git-repo-check")
        }
        args.append(contentsOf: ["resume", sessionId, "-"])
        return args
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        inputText: String
    ) -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice

        let inputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return (127, "Failed to launch \(executableURL.path)")
        }

        if let data = inputText.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
        }
        inputPipe.fileHandleForWriting.closeFile()

        process.waitUntilExit()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errorData, encoding: .utf8) ?? ""
        return (process.terminationStatus, errorText)
    }

    private static func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["CODEX_DEBUG_LOG"] == "1" else { return }
        NSLog("[CodexCliSender] %@", message)
    }
    #endif
}
