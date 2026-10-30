import SwiftUI

/// Onboarding step 3 / Settings "Agents": connect Claude Code and Codex. Nothing is written before the
/// user has seen the diff and pressed Connect.
struct AgentsStepBody: View {
    private let connections = AgentConnections.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Perch shows when Claude Code or Codex needs your input or finishes. Connecting adds Perch's hooks to the agent's config; your other hooks stay as they are.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let change = connections.pending {
                HookDiffView(change: change, connections: connections)
            } else {
                ForEach(AgentConnections.agents, id: \.self) { agent in
                    AgentRow(agent: agent, connections: connections)
                }
            }
        }
        // Codex records approval in its own config; keep the status current while this is on screen.
        .task {
            while !Task.isCancelled {
                connections.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct AgentRow: View {
    let agent: AgentSource
    let connections: AgentConnections

    var body: some View {
        let status = connections.status(of: agent)
        let installed = connections.isInstalled(agent)
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: agent == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent == .claude ? "Claude Code" : "Codex")
                        .font(.system(size: 13, weight: .semibold))
                    if let version = connections.versions[agent] {
                        Text(version).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if connections.isUntested(agent) {
                        Text("Untested version")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                statusText(status, installed: installed)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                if let error = connections.errors[agent] {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            switch status {
            case .disconnected:
                Button("Connect…") { connections.prepareConnect(agent) }
                    .disabled(!installed)
            case .needsReconnect:
                Button("Reconnect…") { connections.prepareConnect(agent) }
            case .awaitingApproval, .connected:
                Button("Disconnect…") { connections.prepareDisconnect(agent) }
            }
        }
    }

    private func statusText(_ status: AgentConnections.Status, installed: Bool) -> Text {
        switch status {
        case .disconnected:
            Text(installed ? "Not connected" : "Not found on this Mac").foregroundStyle(.secondary)
        case .needsReconnect:
            Text("Hooks point at another copy of Perch").foregroundStyle(.orange)
        case .awaitingApproval:
            Text("Open Codex and approve Perch's hooks when it asks").foregroundStyle(.orange)
        case .connected:
            Text("Connected").foregroundStyle(.green)
        }
    }
}

/// The exact change to the agent's config, before anything is written.
private struct HookDiffView: View {
    let change: AgentConnections.PendingChange
    let connections: AgentConnections

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(change.isRemoval ? "Remove Perch from" : "Add Perch to") \(change.path)")
                .font(.system(size: 13, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(change.diff) { line in
                        Text(prefix(line.kind) + line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.kind == .gap ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .background(background(line.kind))
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 180)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { connections.cancelPending() }
                Button(change.isRemoval ? "Disconnect" : "Connect") { connections.confirmPending() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var note: String {
        var text = "A backup is saved next to the file first."
        if change.agent == .codex, !change.isRemoval {
            text += " Codex runs new hooks only after you approve them; it asks the next time it starts."
        }
        return text
    }

    private func prefix(_ kind: UnifiedDiff.Line.Kind) -> String {
        switch kind {
        case .added: "+ "
        case .removed: "- "
        case .context: "  "
        case .gap: ""
        }
    }

    private func background(_ kind: UnifiedDiff.Line.Kind) -> Color {
        switch kind {
        case .added: .green.opacity(0.18)
        case .removed: .red.opacity(0.18)
        case .context, .gap: .clear
        }
    }
}
