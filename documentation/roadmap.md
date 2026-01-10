# Product Roadmap

## MVP (v1.0)

1. [ ] **Disk scanner core** — Recursively scan folders and calculate sizes `M`
   Why first: Everything else depends on accurate size data

2. [ ] **Snapshot storage** — SQLite database to store folder sizes with timestamps `S`
   Why next: Need persistence before we can compare over time

3. [ ] **Delta calculation** — Compare snapshots to show what grew/shrank `S`
   Why next: This is the core differentiator – unlocks the main value

4. [ ] **Main app window** — SwiftUI list view showing growth data `M`
   Why next: Need UI to display the deltas

5. [ ] **Background scheduler** — Periodic snapshot task (hourly default) `S`
   Why next: Enables automatic tracking without manual scans

6. [ ] **Menu bar companion** — Free space display + quick access to app `S`
   Why next: Passive awareness layer

7. [ ] **Low-space alerts** — Threshold-based notifications `XS`
   Why next: Lightweight, adds "emergency mode" trigger

8. [ ] **Settings UI** — Paths, thresholds, snapshot frequency, history retention `M`
   Why next: Lets users customize behavior

9. [ ] **First-launch scan + onboarding** — Initial full scan with progress UI `S`
   Why last in MVP: Polish layer once core works

## Post-MVP (v2.0+)

10. [ ] **Category detection** — Identify folder types (node_modules, Xcode cache, etc.) `M`
11. [ ] **Category grouping view** — "All npm packages: +8GB across 12 projects" `S`
12. [ ] **Smart cleanup suggestions** — Know what's safe to delete `L`
13. [ ] **One-click cleanup actions** — Clear cache, remove node_modules, etc. `M`
14. [ ] **Visual treemap** — Growth visualization like DaisyDisk `L`
15. [ ] **Selective cleanup UI** — Scan-and-select flow like CleanMyMac `L`
16. [ ] **Package-level intelligence** — Understand package managers, selective uninstall `XL`

> **Effort scale**
> - `XS`: 1 day
> - `S`: 2-3 days
> - `M`: 1 week
> - `L`: 2 weeks
> - `XL`: 3+ weeks

> **Notes**
> - Ordered by dependencies and value
> - Each item is a complete, testable feature
> - Check off as specs are implemented
