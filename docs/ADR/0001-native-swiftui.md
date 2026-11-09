# ADR-0001: Native Swift / SwiftUI, iOS 26+

**Status:** Accepted — 2026-11-09

## Context
The app's hardest integrations are HealthKit (read/write, background delivery), VisionKit barcode scanning, widgets and App Intents. A web client is a later, secondary target.

## Decision
Build the iOS app natively in Swift 6 / SwiftUI with a minimum deployment target of iOS 26.0. No cross-platform framework. No UIKit except thin wrappers around system APIs.

## Consequences
- Best integration quality and smallest dependency footprint; single-version target removes availability checks.
- The web client (phase 4) is a separate codebase sharing only the data schema and sync protocol.
- Contributors need a Mac with Xcode 26.
