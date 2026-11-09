# Phase 0 checklist

- [ ] Create public GitHub repo, push these files (`main` protected, squash merges, require CI)
- [ ] Replace `<YOUR NAME>` in `LICENSE`, `<you>` in README/xcconfig template
- [ ] Decide final app name & bundle ID (working: NutriLog, `hr.<yourname>.nutrilog`)
- [ ] Xcode 26: create `NutriLog.xcodeproj` (iOS App, SwiftUI, Swift 6), add local packages from `Packages/`
- [ ] Add `Config/Secrets.xcconfig` to project build settings; expose `USDA_FDC_API_KEY` via Info.plist
- [ ] Enable HealthKit capability + Background Delivery; add `NSHealthShareUsageDescription`, `NSHealthUpdateUsageDescription`, `NSCameraUsageDescription`
- [ ] Create remaining package skeletons: Core, FoodSources, HealthKitClient, Scanner, DesignSystem (same Package.swift pattern; add to CI matrix)
- [ ] Add SwiftFormat + SwiftLint configs
- [ ] Run `swift test` in `Packages/Persistence` → green; CI green on first PR
- [ ] Download FDC CSVs, run `tools/build_food_index.py`, commit `Resources/FoodIndex/bundled_foods.sqlite`
- [ ] App Store Connect: create app record, TestFlight internal group; store API key in GitHub secrets; enable `testflight` job
- [ ] Run `tools/import_issues.sh` to create labels, milestones and Phase 1–3 issues; add them to a Project board
