//
//  HistorySearchView.swift
//  ClaudeIsland
//
//  History search panel — search all past sessions by keyword,
//  grouped by date or by project. Supports opening full transcript.
//

import SwiftUI

struct HistorySearchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @StateObject private var manager = HistorySearchManager.shared

    @State private var searchText: String = ""
    @State private var groupMode: HistoryGroupMode = .byDate
    @State private var selectedSession: HistorySession?
    @State private var transcriptMessages: [TranscriptMessage]?
    @State private var isLoadingTranscript: Bool = false
    @State private var collapsedSections: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if let session = selectedSession {
                // Detail view: full transcript
                transcriptDetailView(session: session)
            } else {
                // List view: sessions + search
                headerRow
                searchBar

                if !searchText.isEmpty {
                    searchResultsList
                } else {
                    sessionsList
                }
            }
        }
        .onAppear {
            manager.loadSessions()
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Button(action: { viewModel.contentType = .instances }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("返回")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)

            Spacer()

            Text("历史对话")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))

            Spacer()

            // Group mode toggle
            Picker("", selection: $groupMode) {
                ForEach(HistoryGroupMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 100)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Transcript Detail View

    private func transcriptDetailView(session: HistorySession) -> some View {
        VStack(spacing: 0) {
            // Detail header
            HStack {
                Button(action: {
                    selectedSession = nil
                    transcriptMessages = nil
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("返回列表")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(.plain)

                Spacer()

                VStack(spacing: 2) {
                    Text(session.firstMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(1)
                    Text("\(session.dateDisplay) \(session.timeDisplay)")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().background(Color.white.opacity(0.1))

            // Transcript content
            if isLoadingTranscript {
                VStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("加载对话...")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let messages = transcriptMessages {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { msg in
                            TranscriptMessageRow(message: msg)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                Text("无内容")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.4))

            TextField("搜索对话内容...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .onSubmit {
                    manager.search(query: searchText)
                }
                .onChange(of: searchText) { newValue in
                    if newValue.isEmpty {
                        manager.searchResults = []
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            if searchText == newValue {
                                manager.search(query: newValue)
                            }
                        }
                    }
                }

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.06))
        .cornerRadius(8)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Search Results

    private var searchResultsList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if manager.isSearching {
                loadingView("搜索中...")
            } else if manager.searchResults.isEmpty {
                emptyView("无匹配结果")
            } else {
                LazyVStack(spacing: 2) {
                    Text("\(manager.searchResults.count) 条结果")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)

                    ForEach(manager.searchResults) { result in
                        SearchResultRow(result: result, query: searchText)
                            .onTapGesture {
                                openSessionById(result.sessionId, project: result.project)
                            }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Sessions List

    private var sessionsList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if manager.isLoading {
                loadingView("加载中...")
            } else if manager.sessions.isEmpty {
                emptyView("无历史 session")
            } else {
                LazyVStack(spacing: 0) {
                    switch groupMode {
                    case .byDate:
                        ForEach(manager.sessionsByDate, id: \.key) { group in
                            collapsibleSection(key: group.key, title: group.display, count: group.sessions.count) {
                                ForEach(group.sessions) { session in
                                    SessionHistoryRow(session: session, showProject: true)
                                        .onTapGesture {
                                            openSession(session)
                                        }
                                }
                            }
                        }
                    case .byProject:
                        ForEach(manager.sessionsByProject, id: \.key) { group in
                            collapsibleSection(key: group.key, title: group.display, count: group.sessions.count) {
                                ForEach(group.sessions) { session in
                                    SessionHistoryRow(session: session, showProject: false)
                                        .onTapGesture {
                                            openSession(session)
                                        }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func collapsibleSection<Content: View>(key: String, title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        let isCollapsed = collapsedSections.contains(key)

        // Section header (tappable toggle)
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isCollapsed {
                    collapsedSections.remove(key)
                } else {
                    collapsedSections.insert(key)
                }
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(width: 12)

                if groupMode == .byProject {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.blue.opacity(0.7))
                } else {
                    Image(systemName: "calendar")
                        .font(.system(size: 10))
                        .foregroundColor(.purple.opacity(0.7))
                }

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))

                Text("\(count)")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(4)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.05))
            .cornerRadius(6)
            .padding(.horizontal, 8)
            .padding(.top, 6)
        }
        .buttonStyle(.plain)

        // Content (hidden when collapsed)
        if !isCollapsed {
            content()
        }
    }

    private func loadingView(_ text: String) -> some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 40)
    }

    private func emptyView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.3))
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
    }

    private func openSession(_ session: HistorySession) {
        selectedSession = session
        loadTranscript(sessionId: session.id, project: session.project)
    }

    private func openSessionById(_ sessionId: String, project: String) {
        // Find session in list or create a minimal one
        if let session = manager.sessions.first(where: { $0.id == sessionId }) {
            selectedSession = session
        } else {
            selectedSession = HistorySession(
                id: sessionId,
                project: project,
                projectDisplay: project,
                title: "...",
                firstMessage: "...",
                lastMessage: "...",
                timestamp: Date(),
                fileSize: 0
            )
        }
        loadTranscript(sessionId: sessionId, project: project)
    }

    private func loadTranscript(sessionId: String, project: String) {
        isLoadingTranscript = true
        transcriptMessages = nil

        Task.detached {
            let messages = HistorySearchManager.loadTranscript(sessionId: sessionId, project: project)
            await MainActor.run {
                transcriptMessages = messages
                isLoadingTranscript = false
            }
        }
    }
}

// MARK: - Transcript Message Model

struct TranscriptMessage: Identifiable {
    let id: String
    let role: String // "user" or "assistant"
    let text: String
    let timestamp: String
    let tools: [TranscriptToolCall]
}

struct TranscriptToolCall: Identifiable {
    let id: String
    let name: String
    let summary: String
}

// MARK: - Transcript Message Row

struct TranscriptMessageRow: View {
    let message: TranscriptMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Role + time
            HStack(spacing: 6) {
                Image(systemName: message.role == "user" ? "person.fill" : "cpu")
                    .font(.system(size: 9))
                    .foregroundColor(message.role == "user" ? .blue.opacity(0.8) : .green.opacity(0.8))

                Text(message.role == "user" ? "User" : "Assistant")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(message.role == "user" ? .blue.opacity(0.7) : .green.opacity(0.7))

                Spacer()

                Text(message.timestamp)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
            }

            // Content
            Text(message.text)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(nil)
                .textSelection(.enabled)

            // Tool calls
            if !message.tools.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(message.tools) { tool in
                        HStack(spacing: 4) {
                            Image(systemName: "wrench.fill")
                                .font(.system(size: 8))
                                .foregroundColor(.orange.opacity(0.6))
                            Text(tool.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.orange.opacity(0.7))
                            Text(tool.summary)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.4))
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(Color.white.opacity(0.03))
                        .cornerRadius(4)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(10)
        .background(message.role == "user" ? Color.blue.opacity(0.05) : Color.green.opacity(0.03))
        .cornerRadius(8)
    }
}

// MARK: - Session History Row

struct SessionHistoryRow: View {
    let session: HistorySession
    var showProject: Bool = true

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.firstMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(session.timeDisplay)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))

                    Text("·")
                        .foregroundColor(.white.opacity(0.2))

                    Text(formatSize(session.fileSize))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))

                    if showProject {
                        Text("·")
                            .foregroundColor(.white.opacity(0.2))

                        Text(session.projectDisplay)
                            .font(.system(size: 10))
                            .foregroundColor(.blue.opacity(0.5))
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.2))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.02))
        .cornerRadius(6)
        .padding(.horizontal, 8)
    }

    private func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024)KB" }
        return String(format: "%.1fMB", Double(bytes) / 1024.0 / 1024.0)
    }
}

// MARK: - Search Result Row

struct SearchResultRow: View {
    let result: HistorySearchResult
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: result.role == "user" ? "person.fill" : "cpu")
                    .font(.system(size: 9))
                    .foregroundColor(result.role == "user" ? .blue.opacity(0.7) : .green.opacity(0.7))

                Text(result.timeDisplay)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))

                Text("·")
                    .foregroundColor(.white.opacity(0.2))

                Text(result.projectDisplay)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
                    .lineLimit(1)

                Spacer()
            }

            Text(result.snippet)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
        .cornerRadius(6)
        .padding(.horizontal, 8)
    }
}
