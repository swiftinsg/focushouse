
## Tester mode (beta only, remove before release)
Settings → Testing → "Tester mode" (on by default, App Group key `testerMode`) relaxes the anti-gaming rules so testers can try everything quickly. All in `Shared/Tester.swift`; each bypass is a `Tester.on` marked `TESTER:` (grep it). The strict rules are kept as-is underneath. Relaxed while on:
- Ticking before a task starts still earns bricks (`PlanTask.tickedEarly`).
- Bricks without answering "How did it go?" (`PlanTask.earnsBricks`; widget ticks too).
- No 2 h per-task cap (`House.bricks`), no half rate after 60 / cap of 100 a day (`House.dayTotal`), no 10 to-dos a day limit (`HouseStatus`).
- Phone-down time during a scheduled task or lesson counts as rest (`RestMonitor`).
Unit tests always run with it off. For the final version: delete `Tester.swift`, the Settings "Testing" section and each `Tester.on`, then run xcodegen; or set the default to false to keep it for internal builds.
