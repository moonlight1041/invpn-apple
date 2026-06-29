// The real telemetry sources live in ApplicationLibrary/InVPN/Telemetry/ (compiled
// into the app, zero pbxproj). CI copies them here before `swift test`
// (see .github/workflows/telemetry-tests.yml). This stub keeps the SwiftPM target
// non-empty when checked out without that copy.
enum _TelemetryKitCISync {}
