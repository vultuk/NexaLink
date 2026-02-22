# NexaLink

NexaLink is a SwiftUI app that connects to one or more Codex app-server WebSocket endpoints, merges their threads into one UI, and lets you work in project-scoped conversations from macOS, iPad, and iPhone.

## What this project does
- Connects to multiple app-server instances over WebSocket (`ws://host:port`).
- Merges thread lists and running-task activity across all enabled connections.
- Groups threads by project folder, with connection identity and color.
- Lets you connect a project folder, start new thread work, continue existing threads, and archive threads.
- Supports model/reasoning selection and plan mode in the composer.
- Renders streamed conversation output with markdown formatting.

## How it works (high level)
- `MultiAppServerConnectionStore` manages all configured connections and publishes merged app state.
- `AppServerConnection` handles per-server WebSocket transport, request/response tracking, and event parsing.
- Feature coordinators/controllers keep side effects out of leaf UI:
- `AppConnectionsCoordinator` owns connect-project/settings flow.
- `ThreadSelectionSideEffectsController` owns selection/archive side effects.
- `ComposerTaskCoordinator` owns task-start and composer override sanitization.
- `ContentView` composes features and wires published state to UI.

## Project structure
- `schema-agent/App`: app entry and main composition.
- `schema-agent/Core/Networking`: socket + protocol handling.
- `schema-agent/Core/Store`: merged connection/thread/task state.
- `schema-agent/Features/Composer`: composer UI + task-start coordination.
- `schema-agent/Features/Connections`: settings + connect-project wizard.
- `schema-agent/Features/Conversation`: timeline/markdown/running-task rendering.
- `schema-agent/Features/Threads`: sidebar and thread/project selection behavior.
- `schema-agent/Shared/Support`: shared types/helpers.

## Requirements
- macOS with Xcode installed.
- A running Codex app-server endpoint.
- iOS Simulator runtime if you want to run iPhone/iPad builds.

## Running NexaLink
1. Start one or more app servers.
2. Open `schema-agent.xcodeproj` in Xcode.
3. Select the `schema-agent` scheme.
4. Run on `My Mac` or an iOS Simulator.

### Start a local app-server (example)
```bash
codex app-server
```

Default local endpoint is usually:
```text
ws://127.0.0.1:9281
```

If your remote app-server binds localhost only, use SSH port forwarding:
```bash
ssh -L 9281:127.0.0.1:9281 <remote-host>
```

## First-time app setup
1. Open **Settings** in the sidebar.
2. In **Connections**, add one or more connections (name, host, port, color).
3. Enable the connections you want active.
4. Click **Connect project**.
5. Choose a connection.
6. Choose or enter a folder path.
7. Create/select the project context.
8. Enter a prompt in the composer and send.

## Build from terminal
From repo root:

```bash
xcodebuild -project schema-agent.xcodeproj -scheme schema-agent -destination 'platform=macOS' build
```

```bash
xcodebuild -project schema-agent.xcodeproj -scheme schema-agent -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## Notes and troubleshooting
- If no threads appear, verify connections are enabled and the servers are reachable.
- If WebSocket connection fails, confirm host/port and that app-server is running.
- For remote hosts, SSH forwarding is often required when server binds `127.0.0.1`.
- On first run, a default local connection is migrated/saved in app preferences.

## Contributing
Use `AGENTS.md` in the repo root as the implementation standard for:
- SOLID and DRY rules.
- architecture and ownership boundaries.
- required validation and regression checks.
