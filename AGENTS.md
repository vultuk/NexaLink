# AGENTS.md

## Purpose
This file defines how code should be changed in NexaLink.
Primary goals:
- Keep the codebase SOLID.
- Keep the codebase DRY.
- Preserve cross-platform behavior on macOS, iPad, and iPhone.
- Avoid UI regressions and performance regressions.

## Product Context
NexaLink is a SwiftUI desktop/mobile client for Codex app-server connections.
It merges threads and activity across one or more remote/local websocket connections.

## Current Structure (source of truth)
- `schema-agent/App`: app entry and screen composition only.
- `schema-agent/Core/Networking`: websocket protocol, framing, parsing, server message handling.
- `schema-agent/Core/Store`: multi-connection orchestration, derived state, persistence.
- `schema-agent/Features/Composer`: composer input, task start coordination, model/reasoning selection.
- `schema-agent/Features/Connections`: settings, connection CRUD, connect-project flow.
- `schema-agent/Features/Conversation`: timeline rendering, markdown rendering, attachments, running-task cards.
- `schema-agent/Features/Threads`: sidebar, project/thread identity, selection/archive side effects.
- `schema-agent/Shared/Support`: shared feature-agnostic types and helpers.

## Architectural Rules (SOLID)
1. Single Responsibility
- Each type must have one reason to change.
- `View` types render UI and delegate side effects.
- Side effects belong in coordinators/controllers/store, not inside row views.

2. Open/Closed
- Extend behavior by adding new small types in the relevant feature folder.
- Prefer new strategy/helper types over modifying large existing switch blocks repeatedly.

3. Liskov Substitution
- Keep model contracts stable.
- If replacing a type, preserve existing call semantics and threading expectations.

4. Interface Segregation
- Prefer narrow APIs.
- Avoid exposing large “god” objects to leaf views.
- Pass only the data/actions a view needs.

5. Dependency Inversion
- High-level UI should depend on abstractions or small facades/coordinators.
- Keep protocol/transport details in `Core/Networking`.

## DRY Rules
- Do not duplicate thread/project identity logic. Reuse `ProjectIdentity.swift` helpers.
- Do not duplicate composer override sanitization. Reuse coordinator/support types.
- Do not duplicate connection URL normalization/validation logic. Reuse helpers in the Connections feature.
- Do not duplicate markdown parsing rules. Keep markdown behavior centralized.
- If you copy/paste more than ~10 lines, stop and extract shared code.

## File Size and Decomposition Policy
- Do not add new logic directly into `ContentView` unless it is pure composition glue.
- Any new side-effect workflow must be implemented in a dedicated coordinator/controller.
- Prefer extracting once a file exceeds ~350 lines or has more than one domain concern.
- Keep view rows/cards small and reusable.

## State Ownership Rules
- App/global merged state belongs in `MultiAppServerConnectionStore`.
- Feature workflow UI state belongs in feature coordinators (example: connect-project flow).
- Ephemeral local visual state belongs in the local view.
- Avoid “mirrored state” in multiple places unless there is a documented cache reason.

## Concurrency and Threading Rules
- UI state updates occur on the main actor.
- Never perform heavy parsing, sorting, or pagination loops on the main thread.
- Do not block user interactions during network pagination or archive operations.
- Use incremental updates and request generations/cancellation guards for async flows.

## Performance Rules
- Keep first paint and initial thread list load responsive.
- Avoid full-list recomputation when a scoped update will do.
- Keep sidebar and conversation caches stable to prevent unnecessary layout churn.
- Any operation that can run repeatedly from stream events must be O(incremental) where practical.

## UI/UX Behavior Rules
- Respect platform-specific behavior already implemented:
  - iPhone compact patterns.
  - iPad/mac split-view behavior.
  - Composer input behavior (`Enter` sends, `Shift+Enter` newline where supported).
- Do not reintroduce duplicate toggles/buttons for the same action.
- Keep message rendering markdown-capable and readable.

## Networking/App-Server Rules
- Follow schema behavior from `json-schema/` and app-server docs.
- Agents may use files in `@json-schema` (repo folder: `json-schema/`) as a local reference for request/response shapes and protocol details.
- For full and current app-server API behavior, consult `https://developers.openai.com/codex/app-server` as the authoritative reference.
- Be conservative in parser changes: unknown fields should not crash parsing.
- Support partial/incremental payloads and out-of-order events safely.
- Archive/list/history actions must update UI state immediately and deterministically.

## Error Handling Rules
- Fail with actionable user-visible messages.
- Never silently swallow errors in flows that the user initiates.
- Keep retry paths explicit for network operations.

## Naming and Style
- Use clear, domain-based names: `...Coordinator`, `...Controller`, `...Store`, `...View`.
- Keep methods small and intention-revealing.
- Prefer value types for plain models; reference types for shared mutable orchestration.
- Add concise comments only where intent is non-obvious.

## Change Validation (required)
For non-trivial changes, run:
1. `xcodebuild -project schema-agent.xcodeproj -scheme schema-agent -destination 'platform=macOS' build`
2. `xcodebuild -project schema-agent.xcodeproj -scheme schema-agent -destination 'platform=iOS Simulator,name=iPhone 17' build`

If a build cannot be run, state exactly why.

## Regression Checklist
Before finishing, verify:
1. Thread list loads for all enabled connections.
2. Archive updates list immediately.
3. Selecting a thread shows current and historical activity without switching away/back.
4. Composer sends tasks correctly for both thread and project contexts.
5. Plan mode toggle behavior is correct in both directions.
6. Settings and connect-project flows work on macOS and iPhone layouts.

## Refactor Policy
- Prefer targeted refactors that preserve behavior.
- If a change touches multiple domains, split into sequential commits/patches by concern.
- Do not mix visual restyling with transport/protocol logic in one patch.

## Forbidden Patterns
- Massive all-in-one view/state files.
- Duplicated parsing logic in multiple files.
- Business logic hidden inside SwiftUI row subviews.
- Main-thread blocking loops over all threads/messages during frequent updates.

## When Unsure
- Choose the design that reduces coupling and duplicate logic.
- Choose explicit data flow over implicit side effects.
- Choose maintainability over short-term shortcut code.
