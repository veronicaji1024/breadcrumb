//
//  HistorySearchManager.swift
//  ClaudeIsland
//
//  Scans all Claude Code session JSONL files and provides search across all history.
//  Groups results by date and by project.
//

import Combine
import Foundation
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "HistorySearch")

/// A single session's metadata
struct HistorySession: Identifiable, Sendable {
    let id: String // sessionId
    let project: String // project directory name
    let projectDisplay: String // human-readable project path
    let title: String // short generated title
    let firstMessage: String // first user message (shown as subtitle)
    let lastMessage: String // most recent user message
    let timestamp: Date
    let fileSize: Int64

    var dateKey: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: timestamp)
    }

    var dateDisplay: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: timestamp)
    }

    var timeDisplay: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: timestamp)
    }
}

/// A search result hit
struct HistorySearchResult: Identifiable, Sendable {
    let id: String // unique id
    let sessionId: String
    let project: String
    let projectDisplay: String
    let role: String // "user" or "assistant"
    let timestamp: Date
    let snippet: String // text around the match
    let matchRange: Range<String.Index>? // for highlighting

    var timeDisplay: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: timestamp)
    }
}

/// Groups sessions by date or by project
enum HistoryGroupMode: String, CaseIterable {
    case byDate = "日期"
    case byProject = "项目"
}

@MainActor
class HistorySearchManager: ObservableObject {
    static let shared = HistorySearchManager()

    @Published var sessions: [HistorySession] = []
    @Published var searchResults: [HistorySearchResult] = []
    @Published var isLoading: Bool = false
    @Published var isSearching: Bool = false

    private let projectsDir: String

    init() {
        self.projectsDir = NSHomeDirectory() + "/.claude/projects"
    }

    /// Scan all sessions (call on appear)
    func loadSessions() {
        guard !isLoading else { return }
        isLoading = true

        Task.detached { [projectsDir] in
            let sessions = Self.scanSessions(projectsDir: projectsDir)
            await MainActor.run { [weak self] in
                self?.sessions = sessions
                self?.isLoading = false
            }
        }
    }

    /// Search all sessions for a keyword
    func search(query: String) {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }

        isSearching = true

        Task.detached { [projectsDir] in
            let results = Self.performSearch(query: query, projectsDir: projectsDir)
            await MainActor.run { [weak self] in
                self?.searchResults = results
                self?.isSearching = false
            }
        }
    }

    /// Get sessions grouped by date
    var sessionsByDate: [(key: String, display: String, sessions: [HistorySession])] {
        let grouped = Dictionary(grouping: sessions) { $0.dateKey }
        return grouped.keys.sorted(by: >).map { key in
            let items = grouped[key]!.sorted { $0.timestamp > $1.timestamp }
            return (key: key, display: items.first?.dateDisplay ?? key, sessions: items)
        }
    }

    /// Get sessions grouped by project
    var sessionsByProject: [(key: String, display: String, sessions: [HistorySession])] {
        let grouped = Dictionary(grouping: sessions) { $0.project }
        return grouped.keys
            .sorted { a, b in
                // Sort by most recent session timestamp in each group
                let latestA = grouped[a]!.map(\.timestamp).max() ?? .distantPast
                let latestB = grouped[b]!.map(\.timestamp).max() ?? .distantPast
                return latestA > latestB
            }
            .map { key in
                let items = grouped[key]!.sorted { $0.timestamp > $1.timestamp }
                let display = items.first?.projectDisplay ?? key
                return (key: key, display: display, sessions: items)
            }
    }

    // MARK: - Static helpers (run off main thread)

    private nonisolated static func scanSessions(projectsDir: String) -> [HistorySession] {
        let fm = FileManager.default
        var sessions: [HistorySession] = []

        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else {
            return []
        }

        for projectDir in projectDirs {
            let projectPath = projectsDir + "/" + projectDir
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else {
                continue
            }

            for file in files {
                guard file.hasSuffix(".jsonl"),
                      !file.hasPrefix("agent-"),
                      !file.contains("subagent") else {
                    continue
                }

                let filePath = projectPath + "/" + file
                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let modDate = attrs[.modificationDate] as? Date,
                      let fileSize = attrs[.size] as? Int64 else {
                    continue
                }

                // Skip tiny files
                guard fileSize > 200 else { continue }

                let sessionId = String(file.dropLast(6)) // remove .jsonl

                // Read first user message, last user message, and cwd
                let info = readSessionInfo(filePath: filePath)
                guard let firstMsg = info.firstMessage, !firstMsg.isEmpty else { continue }

                let projectDisplay = formatCwd(info.cwd)
                let title = generateTitle(from: firstMsg)
                let lastMsg = info.lastMessage ?? firstMsg

                sessions.append(HistorySession(
                    id: sessionId,
                    project: projectDir,
                    projectDisplay: projectDisplay,
                    title: title,
                    firstMessage: firstMsg,
                    lastMessage: lastMsg,
                    timestamp: modDate,
                    fileSize: fileSize
                ))
            }
        }

        sessions.sort { $0.timestamp > $1.timestamp }
        return sessions
    }

    private nonisolated static func readSessionInfo(filePath: String) -> (firstMessage: String?, lastMessage: String?, cwd: String?) {
        guard let handle = FileHandle(forReadingAtPath: filePath) else { return (nil, nil, nil) }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: 32768),
              let content = String(data: data, encoding: .utf8) else {
            return (nil, nil, nil)
        }

        var cwd: String?
        var firstMsg: String?
        var lastMsg: String?

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            if cwd == nil, let msgCwd = json["cwd"] as? String {
                cwd = msgCwd
            }

            guard json["type"] as? String == "user",
                  json["isMeta"] as? Bool != true,
                  let message = json["message"] as? [String: Any] else {
                continue
            }

            let text = extractText(message["content"])
            guard !text.isEmpty,
                  !text.hasPrefix("<command-name>"),
                  !text.hasPrefix("<local-command"),
                  !text.hasPrefix("Caveat:") else {
                continue
            }

            let cleaned = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            let truncated = String(cleaned.prefix(120))

            if firstMsg == nil {
                firstMsg = truncated
            }
            lastMsg = truncated
        }

        return (firstMsg, lastMsg, cwd)
    }

    private nonisolated static func generateTitle(from message: String) -> String {
        // Use the first sentence or up to 50 characters as title
        let cleaned = message.trimmingCharacters(in: .whitespaces)
        if let dotRange = cleaned.range(of: "。"),
           cleaned.distance(from: cleaned.startIndex, to: dotRange.lowerBound) < 60 {
            return String(cleaned[..<dotRange.lowerBound])
        }
        if let dotRange = cleaned.range(of: ". "),
           cleaned.distance(from: cleaned.startIndex, to: dotRange.lowerBound) < 60 {
            return String(cleaned[..<dotRange.lowerBound])
        }
        if cleaned.count <= 50 {
            return cleaned
        }
        return String(cleaned.prefix(50)) + "..."
    }

    private nonisolated static func readFirstUserMessageAndCwd(filePath: String) -> (String?, String?) {
        guard let handle = FileHandle(forReadingAtPath: filePath) else { return (nil, nil) }
        defer { try? handle.close() }

        // Read first 8KB to find first user message and cwd
        guard let data = try? handle.read(upToCount: 8192),
              let content = String(data: data, encoding: .utf8) else {
            return (nil, nil)
        }

        var cwd: String?
        var firstMsg: String?

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            // Extract cwd from any message that has it
            if cwd == nil, let msgCwd = json["cwd"] as? String {
                cwd = msgCwd
            }

            guard json["type"] as? String == "user",
                  json["isMeta"] as? Bool != true,
                  let message = json["message"] as? [String: Any] else {
                continue
            }

            if firstMsg != nil { continue }

            if let msgContent = message["content"] as? String {
                if msgContent.hasPrefix("<command-name>") || msgContent.hasPrefix("<local-command") || msgContent.hasPrefix("Caveat:") {
                    continue
                }
                let cleaned = msgContent.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                firstMsg = String(cleaned.prefix(120))
            } else if let contentArray = message["content"] as? [[String: Any]] {
                for block in contentArray {
                    if block["type"] as? String == "text", let text = block["text"] as? String {
                        if text.hasPrefix("<command-name>") || text.hasPrefix("<local-command") {
                            continue
                        }
                        let cleaned = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                        firstMsg = String(cleaned.prefix(120))
                        break
                    }
                }
            }

            if firstMsg != nil && cwd != nil { break }
        }

        return (firstMsg, cwd)
    }

    private nonisolated static func performSearch(query: String, projectsDir: String, maxResults: Int = 80) -> [HistorySearchResult] {
        let fm = FileManager.default
        let queryLower = query.lowercased()
        var results: [HistorySearchResult] = []
        var resultId = 0

        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else {
            return []
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for projectDir in projectDirs {
            let projectPath = projectsDir + "/" + projectDir
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else {
                continue
            }

            for file in files {
                guard file.hasSuffix(".jsonl"),
                      !file.hasPrefix("agent-"),
                      !file.contains("subagent") else {
                    continue
                }

                let filePath = projectPath + "/" + file
                let sessionId = String(file.dropLast(6))

                guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
                    continue
                }

                for line in content.components(separatedBy: "\n") where !line.isEmpty {
                    guard let lineData = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                        continue
                    }

                    let msgType = json["type"] as? String
                    guard msgType == "user" || msgType == "assistant" else { continue }
                    guard json["isMeta"] as? Bool != true else { continue }

                    let message = json["message"] as? [String: Any]
                    let text = extractText(message?["content"])
                    guard !text.isEmpty else { continue }

                    let textLower = text.lowercased()
                    guard let range = textLower.range(of: queryLower) else { continue }

                    // Build snippet around match
                    let matchStart = text.distance(from: text.startIndex, to: range.lowerBound)
                    let snippetStart = max(0, matchStart - 60)
                    let snippetEnd = min(text.count, matchStart + query.count + 60)
                    let startIdx = text.index(text.startIndex, offsetBy: snippetStart)
                    let endIdx = text.index(text.startIndex, offsetBy: snippetEnd)
                    var snippet = String(text[startIdx..<endIdx])
                    if snippetStart > 0 { snippet = "..." + snippet }
                    if snippetEnd < text.count { snippet = snippet + "..." }

                    let timestamp: Date
                    if let ts = json["timestamp"] as? String {
                        timestamp = formatter.date(from: ts) ?? Date.distantPast
                    } else {
                        timestamp = Date.distantPast
                    }

                    resultId += 1
                    results.append(HistorySearchResult(
                        id: "r\(resultId)",
                        sessionId: sessionId,
                        project: projectDir,
                        projectDisplay: formatProjectName(projectDir),
                        role: msgType ?? "unknown",
                        timestamp: timestamp,
                        snippet: snippet,
                        matchRange: nil
                    ))

                    if results.count >= maxResults {
                        return results
                    }
                }
            }
        }

        results.sort { $0.timestamp > $1.timestamp }
        return results
    }

    private nonisolated static func extractText(_ content: Any?) -> String {
        if let str = content as? String {
            if str.hasPrefix("<command-name>") || str.hasPrefix("<local-command") { return "" }
            return str
        }
        if let array = content as? [[String: Any]] {
            var texts: [String] = []
            for block in array {
                if block["type"] as? String == "text", let text = block["text"] as? String {
                    if !text.hasPrefix("<command-name>") && !text.hasPrefix("<local-command") {
                        texts.append(text)
                    }
                }
            }
            return texts.joined(separator: "\n")
        }
        return ""
    }

    private nonisolated static func formatCwd(_ cwd: String?) -> String {
        guard let cwd = cwd, !cwd.isEmpty else { return "未知项目" }
        // Replace /Users/username with ~
        let home = NSHomeDirectory()
        if cwd.hasPrefix(home) {
            let relative = String(cwd.dropFirst(home.count))
            if relative.isEmpty || relative == "/" { return "主目录" }
            // Show last 2 path components for clarity
            let components = relative.split(separator: "/").filter { !$0.isEmpty }
            if components.count <= 2 {
                return components.joined(separator: "/")
            }
            // Show last 2 components
            return components.suffix(2).joined(separator: "/")
        }
        // For non-home paths, show last 2 components
        let components = cwd.split(separator: "/").filter { !$0.isEmpty }
        if components.count <= 2 {
            return components.joined(separator: "/")
        }
        return components.suffix(2).joined(separator: "/")
    }

    private nonisolated static func formatProjectName(_ dirName: String) -> String {
        return dirName
    }

    // MARK: - Load full transcript

    nonisolated static func loadTranscript(sessionId: String, project: String) -> [TranscriptMessage] {
        let projectsDir = NSHomeDirectory() + "/.claude/projects"
        let filePath = projectsDir + "/" + project + "/" + sessionId + ".jsonl"

        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return []
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"

        var messages: [TranscriptMessage] = []
        var msgIndex = 0

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let msgType = json["type"] as? String
            guard msgType == "user" || msgType == "assistant" else { continue }
            guard json["isMeta"] as? Bool != true else { continue }

            let messageContent = json["message"] as? [String: Any]
            let rawContent = messageContent?["content"]

            // Timestamp
            let timestampStr: String
            if let ts = json["timestamp"] as? String, let date = formatter.date(from: ts) {
                timestampStr = timeFormatter.string(from: date)
            } else {
                timestampStr = ""
            }

            if msgType == "user" {
                let text = extractText(rawContent)
                if text.isEmpty || text.hasPrefix("<command-name>") || text.hasPrefix("<local-command") || text.hasPrefix("Caveat:") {
                    continue
                }
                msgIndex += 1
                messages.append(TranscriptMessage(
                    id: "msg-\(msgIndex)",
                    role: "user",
                    text: text,
                    timestamp: timestampStr,
                    tools: []
                ))
            } else if msgType == "assistant" {
                var texts: [String] = []
                var tools: [TranscriptToolCall] = []
                var toolIndex = 0

                if let str = rawContent as? String {
                    texts.append(str)
                } else if let array = rawContent as? [[String: Any]] {
                    for block in array {
                        let blockType = block["type"] as? String
                        if blockType == "text", let text = block["text"] as? String {
                            if !text.hasPrefix("[Request interrupted") {
                                texts.append(text)
                            }
                        } else if blockType == "tool_use" {
                            toolIndex += 1
                            let toolName = block["name"] as? String ?? "unknown"
                            let toolInput = block["input"] as? [String: Any] ?? [:]
                            let summary = summarizeToolCall(name: toolName, input: toolInput)
                            tools.append(TranscriptToolCall(
                                id: "tool-\(msgIndex)-\(toolIndex)",
                                name: toolName,
                                summary: summary
                            ))
                        }
                    }
                }

                let text = texts.joined(separator: "\n")
                if text.isEmpty && tools.isEmpty { continue }

                msgIndex += 1
                messages.append(TranscriptMessage(
                    id: "msg-\(msgIndex)",
                    role: "assistant",
                    text: text,
                    timestamp: timestampStr,
                    tools: tools
                ))
            }
        }

        return messages
    }

    private nonisolated static func summarizeToolCall(name: String, input: [String: Any]) -> String {
        switch name {
        case "Read":
            return (input["file_path"] as? String ?? "").components(separatedBy: "/").last ?? ""
        case "Write":
            let path = (input["file_path"] as? String ?? "").components(separatedBy: "/").last ?? ""
            let len = (input["content"] as? String)?.count ?? 0
            return "\(path) [\(len)c]"
        case "Edit":
            return (input["file_path"] as? String ?? "").components(separatedBy: "/").last ?? ""
        case "Bash":
            let cmd = input["command"] as? String ?? ""
            return String(cmd.prefix(80))
        case "Glob":
            return input["pattern"] as? String ?? ""
        case "Grep":
            return "'\(input["pattern"] as? String ?? "")'"
        case "Agent":
            return input["description"] as? String ?? ""
        case "WebSearch":
            return input["query"] as? String ?? ""
        case "WebFetch":
            return String((input["url"] as? String ?? "").prefix(60))
        default:
            return ""
        }
    }
}

