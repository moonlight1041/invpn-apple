# Task B.5 — Telemetry Facade + Consent Gate + Observe-Only Tunnel Hooks

## Architectural decision: injectable hooks (not direct calls)

The task spec says to add `Task { await Telemetry.record(...) }` directly in
`CommandClient.swift` and `ExtensionPlatformInterface.swift`.

**This is architecturally impossible without a circular import.**

`CommandClient` and `ExtensionPlatformInterface` are compiled into `Library.framework`.
`Telemetry` is in `ApplicationLibrary.framework`, which already links `Library.framework`.
Having `Library` import `ApplicationLibrary` would create a circular dependency
(Library ← ApplicationLibrary ← Library), which Xcode/Swift does not allow.

**Solution**: `Library` exposes three public static `@Sendable` closure vars on
`CommandClient` and one on `ExtensionPlatformInterface`. `Telemetry.installHooks()`
(in `ApplicationLibrary`) sets them to closures that call `Telemetry.record(...)`.
The functional result is identical to direct calls; the indirection is invisible to callers.

---

## Exact lines added to CommandClient.swift

### Static hook vars (after `convenience init`, before `setupMockData`)

```swift
public static var telemetryOnConnected: (@Sendable () -> Void)?
public static var telemetryOnDisconnected: (@Sendable () -> Void)?
public static var telemetryOnConnectionError: (@Sendable (ConnectionError.Kind, String) -> Void)?
```

### Hook in `reportConnectError(token:error:)` — observe-only proof

Surrounding existing code (unchanged):
```swift
private func reportConnectError(token: UInt64, error: Error) async {
    await MainActor.run { [self] in
        guard token == activeConnectionToken else { return }   // ← guard unchanged
        lastError = ConnectionError(kind: .connectFailed, message: error.localizedDescription)
        // === ADDED (inside the guard — only fires when error is actually reported) ===
        let msg = error.localizedDescription
        Task { CommandClient.telemetryOnConnectionError?(.connectFailed, msg) }
    }                                                          // ← close unchanged
}
```

No existing lines removed or altered; new `Task { }` is inside the guard.

### Hook in `clientHandler.connected()` — observe-only proof

```swift
commandClient.isConnected = true          // ← existing line unchanged
// === ADDED ===
Task { CommandClient.telemetryOnConnected?() }
```
Appended after the last existing statement in the `DispatchQueue.main.async` block.

### Hooks in `clientHandler.disconnected(_:)` — observe-only proof

```swift
if let message {
    commandClient.lastError = ConnectionError(kind: .connectionLost, message: message)  // unchanged
    // === ADDED ===
    Task { CommandClient.telemetryOnConnectionError?(.connectionLost, message) }
}
commandClient.isConnected = false         // ← existing line unchanged
// === ADDED ===
Task { CommandClient.telemetryOnDisconnected?() }
```

---

## Exact lines added to ExtensionPlatformInterface.swift

### Static hook var (new, above `writeLog`)

```swift
public static var telemetryOnLog: (@Sendable (String) -> Void)?
```

### Hook in `writeLog(_:)` — observe-only proof

```swift
tunnel.writeMessage(message)              // ← existing line unchanged; NOT replaced
// === ADDED (after, not instead of) ===
Task { ExtensionPlatformInterface.telemetryOnLog?(message) }
```

The `writeLog` hook is always nil in the NE process (Library only; ApplicationLibrary
not loaded there) → graceful no-op in NE. In the main-app process, `installHooks()`
sets it to filter for error keywords and call `Telemetry.record(.degradation)`.

---

## Consent gate

`SharedPreferences.telemetryConsentGiven` (Preference<Bool>, key
`"telemetry_consent_given"`, default `false`) is checked at the top of
`Telemetry.record()`.  `Telemetry.installHooks()` may be called at any time
(even before consent); every hook creates a `Task { await record(...) }` that
immediately returns when consent is false.

The preference lives in the app-group GRDB `preferences` table (survives logout;
cleared only by explicit user action). Device ID (`telemetryDeviceId`) follows the
same scheme.

---

## B.1/B.4 compile fixes included in this commit

Prior tasks created `TelemetryStore.swift` and `ContextCollector.swift` in
`ApplicationLibrary` but omitted `import Library`.  Both files use Library types
(`Database.sharedWriter`, `Bundle.main.version`) that require it.  Additionally,
`Database` was declared `internal` in Library, making `sharedWriter` invisible
outside the module.  This commit fixes all three:

- `Library/Database/Database.swift`: `enum Database` → `public enum Database`;
  `static let sharedWriter` → `public static let sharedWriter: any DatabaseWriter`.
- `ApplicationLibrary/InVPN/Telemetry/TelemetryStore.swift`: added `import Library`.
- `ApplicationLibrary/InVPN/Telemetry/ContextCollector.swift`: added `import Library`.

---

## Compile risks

| Risk | Severity | Notes |
|------|----------|-------|
| `ISO8601DateFormatter` static shared instance | Low | `Formatter` subclasses are technically not thread-safe per Apple docs, but `string(from:)` in practice has no write-side effects after init. Only one formatter; all options set at init. If warnings appear, replace with local `let iso = ISO8601DateFormatter()` inside `record()`. |
| `@Sendable` closures on static vars | Low | Mutable static vars accessed from async context may generate Swift strict-concurrency warnings (`nonisolated(unsafe)` would silence them). Project appears to be in Swift 5 mode; these will be warnings at most, not errors. |
| `ExtensionPlatformInterface.telemetryOnLog` no-op in NE | Info | By design. The NE process does not load ApplicationLibrary; the hook remains nil. Main-app `writeLog` calls (if any) will work. NE-side log telemetry requires a future IPC or Library-level DB write approach. |
| `Telemetry.installHooks()` not wired yet | Info | B.7 (consent UI) should call this after consent is granted. Until then all hooks fire, immediately hit the consent gate, and return. Safe. |

---

## Files changed

- `Library/Database/Database.swift` — `enum Database` and `sharedWriter` made public
- `Library/Database/SharedPreferences.swift` — `telemetryConsentGiven` + `telemetryDeviceId`
- `Library/Network/CommandClient.swift` — 3 static hook vars + 3 fire-and-forget `Task { }` calls
- `Library/Network/ExtensionPlatformInterface.swift` — `telemetryOnLog` static var + hook in `writeLog`
- `ApplicationLibrary/InVPN/Telemetry/TelemetryStore.swift` — `import Library` (B.1 fix)
- `ApplicationLibrary/InVPN/Telemetry/ContextCollector.swift` — `import Library` (B.4 fix)
- `ApplicationLibrary/InVPN/Telemetry/Telemetry.swift` — **new file** (facade + consent gate + installHooks)
