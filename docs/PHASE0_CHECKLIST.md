# Phase 0 checklist

- [x] Create public GitHub repo, push these files (`main` protected, squash merges, require CI)
- [x] Replace `<YOUR NAME>` in `LICENSE`, `<you>` in README/xcconfig template
- [x] Decide final app name & bundle ID → **Nutrilog**, `hr.ivanjuric.nutrilog`
- [x] Xcode 26: `Nutrilog.xcodeproj` generated from `project.yml` (XcodeGen), local packages linked
- [x] Add `Config/Secrets.xcconfig` to project build settings; expose `USDA_FDC_API_KEY` via Info.plist
- [x] Enable HealthKit capability + Background Delivery; add `NSHealthShareUsageDescription`, `NSHealthUpdateUsageDescription`, `NSCameraUsageDescription`
- [x] Create remaining package skeletons: Core, FoodSources, HealthKitClient, Scanner, DesignSystem (same Package.swift pattern; add to CI matrix)
- [x] Add SwiftFormat + SwiftLint configs
- [x] Run `swift test` in `Packages/Persistence` → green (done locally); CI green on first PR — pending push
- [x] Download FDC CSVs, run `tools/build_food_index.py`, commit `Resources/FoodIndex/bundled_foods.sqlite`
- [ ] (Phase 2) App Store Connect: create app record, TestFlight internal group; store API key in GitHub secrets (`testflight` job is enabled; steps in `docs/RELEASING.md`)
- [x] Run `tools/import_issues.sh` to create labels, milestones and Phase 1–3 issues (Project board: optional, not created)
