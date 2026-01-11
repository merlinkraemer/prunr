# Phase 6: Popup HIG Redesign - Research

**Researched:** 2025-01-11
**Domain:** macOS Human Interface Guidelines (HIG) compliance for SwiftUI apps
**Confidence:** HIGH

<research_summary>
## Summary

Researched Apple's Human Interface Guidelines and modern SwiftUI/macOS design patterns to redesign Prunr's main popup according to Apple's standards. The existing user-created design guide (`documentation/macos_design_guide2.md`) provides comprehensive metrics, and this research validates and extends it with SwiftUI-specific implementation patterns.

Key findings: macOS design uses an 8pt spacing grid (8/16/24/32pt), with 20pt standard margins and 28pt row heights for lists. SwiftUI provides native components (Settings scene, .listStyle(.inset), Table) that automatically handle most HIG compliance when used correctly.

**Primary recommendation:** Use SwiftUI's native Settings scene for settings windows, .listStyle(.inset(alternatesRowBackgrounds: true)) for the main file list, and follow the documented 20pt/12-24pt spacing system throughout. Don't hand-roll custom spacing or window management - SwiftUI's built-in components handle HIG compliance automatically.
</research_summary>

<standard_stack>
## Standard Stack

### Core
| Library/Component | Version | Purpose | Why Standard |
|-------------------|---------|---------|--------------|
| SwiftUI | macOS 11+ | UI framework | Native HIG compliance, automatic spacing/layout |
| Settings scene | macOS 11+ | Settings window | Standard Command+, handling, proper window behavior |
| Window | macOS 11+ | About/popup windows | Native window management, restoration |
| .listStyle(.inset) | macOS 11+ | File list display | HIG-compliant list appearance, alternating rows |

### Supporting
| Component | Purpose | When to Use |
|-----------|---------|-------------|
| NavigationSplitView | Multi-column layouts | Sidebar navigation patterns |
| Table | Columnar data display | When needing multiple columns, sortable headers |
| Form | Settings groups | Auto-spacing for controls, section grouping |
| Group | Layout organization | Logical grouping without list semantics |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Settings scene | WindowGroup + manual Command+, | Settings scene is automatic, WindowGroup requires manual keyboard handling |
| .listStyle(.inset) | Custom row backgrounds | Custom requires manual spacing calculations, .inset is HIG-compliant |
| SwiftUI Lists | NSTableView (AppKit) | AppKit gives more control but requires manual layout, SwiftUI is declarative |

**Installation:**
No external packages needed. SwiftUI is built into macOS 11+.
</standard_stack>

<architecture_patterns>
## Architecture Patterns

### Recommended Project Structure
```
Prunr/
├── Views/
│   ├── Popover/
│   │   ├── MainPopoverView.swift          # Root container with proper padding
│   │   ├── DriveBarView.swift              # (existing, verify 20pt margins)
│   │   └── GrowthListView.swift            # (update to .inset style)
│   ├── Settings/
│   │   ├── SettingsView.swift              # Use Settings scene
│   │   ├── PathsSettingsView.swift         # 20pt margins, 12-24pt spacing
│   │   ├── BoundariesSettingsView.swift    # Form-based layout
│   │   ├── ThresholdSettingsView.swift     # Toggle/slider controls
│   │   ├── DebugSettingsView.swift         # Developer options
│   │   └── AboutSettingsView.swift         # About section
│   └── Components/
│       ├── StandardSection.swift           # Reusable 20pt margin container
│       └── Spacing.swift                   # Spacing constants
├── App/
│   └── PrunrApp.swift                      # Add Settings scene
└── Utilities/
    └── HIGSpacing.swift                    # 8pt grid constants
```

### Pattern 1: Settings Scene with Automatic Command+,
**What:** SwiftUI's Settings scene automatically creates a proper settings window with menu integration
**When to use:** All macOS apps with settings/preferences
**Example:**
```swift
@main
struct PrunrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Prunr", systemImage: "chart.bar.fill") {
            MainPopoverView()
        }

        Settings {
            SettingsView()
        }
    }
}
```

**Note:** Settings scene automatically adds "Settings..." to app menu but requires manual Command+, handling in macOS 13+ (see Open Questions).

### Pattern 2: Inset List with Alternating Rows
**What:** Use .listStyle(.inset(alternatesRowBackgrounds: true)) for HIG-compliant file lists
**When to use:** Any scrollable list of items (the main growth list)
**Example:**
```swift
struct GrowthListView: View {
    var growthItems: [GrowthItem]

    var body: some View {
        List(growthItems) { item in
            GrowthRowView(item: item)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .listRowSeparator(.hidden)
                .listRowBackground(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Handle row click
                        }
                )
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}
```

### Pattern 3: Standard Spacing with 8pt Grid
**What:** Use 8pt multiples for all spacing (8/12/16/20/24/32pt)
**When to use:** All layout spacing, margins, padding
**Example:**
```swift
enum HIGSpacing {
    static let standard: CGFloat = 16
    static let margin: CGFloat = 20
    static let tight: CGFloat = 8
    static let relaxed: CGFloat = 24
}

struct StandardSection<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HIGSpacing.standard) {
            content
        }
        .padding(.horizontal, HIGSpacing.margin)
        .padding(.vertical, 12)
    }
}
```

### Pattern 4: About Window Layout
**What:** Standard About window with icon, name, version, copyright
**When to use:** About section in Settings or standalone About window
**Example:**
```swift
struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "chart.bar.fill")
                .resizable()
                .frame(width: 80, height: 80)
                .foregroundStyle(.blue)

            Text("Prunr")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Version 1.0.0 (Build 1)")
                .font(.body)
                .foregroundStyle(.secondary)

            Text("© 2025 Merlinkramer")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()
                .padding(.vertical, 8)

            Link("Visit Website", destination: URL(string: "https://github.com/merlinkramer/prunr")!)
                .buttonStyle(.link)
        }
        .frame(width: 400, height: 260)
        .padding(20)
    }
}
```

### Anti-Patterns to Avoid
- **Hardcoded spacing values:** Use the 8pt grid system (8/16/24/32), not random values like 11/13/19
- **Custom row heights:** Let SwiftUI Lists handle row height with defaultMinListRowHeight, don't force custom heights
- **Manual Command+, handling:** Use Settings scene, don't manually handle keyboard shortcuts if possible
- **Non-standard margins:** Always use 20pt margins for window content, not 10pt or 30pt
- **Excessive padding:** Don't add padding inside padding - SwiftUI components already have padding
</architecture_patterns>

<dont_hand_roll>
## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Settings window | Custom WindowGroup with manual sizing | Settings scene | Automatic menu integration, proper behavior, Command+, support |
| File list spacing | Manual padding/spacing on every row | .listStyle(.inset(alternatesRowBackgrounds:)) | HIG-compliant spacing, alternating rows, proper selection |
| Window management | Manual window state tracking | SwiftUI Window/Settings scene | Automatic state restoration, proper macOS behavior |
| Layout spacing | Random padding values | 8pt grid (8/16/24/32pt) | Consistent with HIG, visually harmonious |
| Row backgrounds | Custom colors for selection | .listRowBackground with system colors | Automatic dark mode support, proper selection states |
| About window | Custom credits/legal display | NSAboutPanelOption or standard layout | Users expect standard About window format |

**Key insight:** macOS has 40+ years of UI refinement. SwiftUI's native components encapsulate HIG compliance automatically. Custom spacing, custom layouts, and custom window management almost always create worse UX and require 10x the code.
</dont_hand_roll>

<common_pitfalls>
## Common Pitfalls

### Pitfall 1: Ignoring the 8pt Grid
**What goes wrong:** Spacing looks "off" and UI feels amateurish
**Why it happens:** Using arbitrary numbers (11pt, 13pt, 19pt) instead of 8pt multiples
**How to avoid:** Define constants for 8/16/24/32pt and never use other values
**Warning signs:** Visual tension between elements, "tight" or "loose" feeling

### Pitfall 2: Wrong List Style for macOS
**What goes wrong:** List looks like iOS, not macOS
**Why it happens:** Using .listStyle(.plain) or .listStyle(.grouped) instead of .inset
**How to avoid:** Always use .listStyle(.inset(alternatesRowBackgrounds: true)) for macOS file lists
**Warning signs:** Rows touch edges of window, no alternating backgrounds

### Pitfall 3: Insufficient Margins
**What goes wrong:** Content feels cramped against window edges
**Why it happens:** Using 10-12pt margins instead of 20pt standard
**How to avoid:** Apply 20pt horizontal margins to all window content
**Warning signs:** Text near scrollbar, UI elements touching window frame

### Pitfall 4: Missing Row Insets
**What goes wrong:** List rows have no breathing room
**Why it happens:** Not setting .listRowInsets on list rows
**How to avoid:** Use `.listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))`
**Warning signs:** Text touching edge of list background

### Pitfall 5: Wrong Spacing in Settings Groups
**What goes wrong:** Controls feel either cramped or disconnected
**Why it happens:** Using <12pt or >24pt spacing between related controls
**How to avoid:** Use 12-24pt spacing between controls, 20pt margins for groups
**Warning signs:** Hard to scan controls visually, groups not clear

### Pitfall 6: Manual Command+, Handling
**What goes wrong:** Settings keyboard shortcut doesn't work in macOS 13+
**Why it happens:** Apple removed NSApp.sendAction(#selector(showSettingsWindow)) API
**How to avoid:** Use Settings scene (automatic) or SettingsAccess library for manual handling
**Warning signs:** Command+, does nothing in macOS 13+

### Pitfall 7: Inconsistent Row Heights
**What goes wrong:** List looks uneven, hard to scan
**Why it happens:** Mixing content with different heights without explicit row height
**How to avoid:** Use defaultMinListRowHeight environment value or Table for fixed heights
**Warning signs:** Rows vary in height, misaligned content
</common_pitfalls>

<code_examples>
## Code Examples

### Standard Layout Container
```swift
/// HIG-compliant section with 20pt margins and 12-24pt spacing
struct StandardSection<Content: View>: View {
    let title: String?
    let spacing: CGFloat
    @ViewBuilder let content: Content

    init(title: String? = nil, spacing: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.title = title
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let title {
                Text(title.uppercased())
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }

            content
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
```

### HIG-Compliant Growth List
```swift
struct GrowthListView: View {
    let growthItems: [GrowthItem]

    var body: some View {
        VStack(spacing: 0) {
            // Header with 20pt margins
            HStack {
                Text("Folder Growth")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            // List with inset style and alternating backgrounds
            List(growthItems) { item in
                GrowthRowView(item: item)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }
}

struct GrowthRowView: View {
    let item: GrowthItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 16))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.path)
                    .font(.body)

                Text("+\(item.growth.formatted(.byteCount()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
        }
    }
}
```

### Settings Form with Proper Spacing
```swift
struct PathsSettingsView: View {
    @State private var paths: [TrackedPath] = []

    var body: some View {
        Form {
            Section {
                ForEach(paths) { path in
                    HStack {
                        Toggle(path.path, isOn: .constant(path.isEnabled))
                        Spacer()
                        Button(action: {}) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .listRowSeparator(.hidden)
                }
            } header: {
                Text("Monitored Paths")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
```

### About Section
```swift
struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            // App icon
            Image(systemName: "chart.bar.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .foregroundStyle(.blue)

            // App name
            Text("Prunr")
                .font(.system(size: 24, weight: .bold))

            // Version
            Text("Version 1.0.0")
                .font(.body)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.vertical, 8)

            // Copyright
            Text("© 2025 Merlinkramer\nAll rights reserved.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            // Website link
            Link(verbatim: "github.com/merlinkramer/prunr")
                .font(.caption)
                .buttonStyle(.link)
        }
        .frame(maxWidth: 400, maxHeight: 260)
        .padding(20)
    }
}
```
</code_examples>

<sota_updates>
## State of the Art (2024-2025)

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| WindowGroup for settings | Settings scene | macOS 11 (Big Sur) | Automatic menu integration, proper window behavior |
| .listStyle(.plain) | .listStyle(.inset(alternatesRowBackgrounds:)) | macOS 11 | Native macOS appearance, alternating rows |
| Manual spacing constants | SwiftUI spacing modifiers | macOS 11 | Environment-based spacing, automatic adaptation |
| NSApp.sendAction for settings | Settings scene (or SettingsAccess) | macOS 13 | Legacy API removed, need new approach |
| Custom row backgrounds | .listRowBackground with system colors | macOS 12 | Automatic dark mode support |

**New tools/patterns to consider:**
- **SettingsAccess library (2024)**: Workaround for macOS 13+ Command+, handling issue
- **.formStyle(.grouped)**: macOS 13+ native form styling for settings
- **.scrollContentBackground(.hidden)**: macOS 13+ control over form background
- **inspectorColumnWidth(min:ideal:max:)**: Flexible sidebar widths with persistence

**Deprecated/outdated:**
- **NSApp.sendAction(#selector(showSettingsWindow))**: Removed in macOS 13, use Settings scene
- **Manual list row backgrounds**: Use .listStyle(.inset) instead of custom drawing
- **Hardcoded spacing values**: Use SwiftUI spacing modifiers and environment values
</sota_updates>

<open_questions>
## Open Questions

1. **Command+, keyboard shortcut in macOS 13+**
   - What we know: Settings scene adds menu item but doesn't automatically handle Command+, in macOS 13+
   - What's unclear: Whether Apple has fixed this in macOS 14/15 or if workaround is still needed
   - Recommendation: Test on target macOS versions. Use SettingsAccess library if keyboard shortcut doesn't work. Implement CommandGroup with Command+, if needed.

2. **Best list style for main popup growth list**
   - What we know: .listStyle(.inset(alternatesRowBackgrounds: true)) is HIG-compliant
   - What's unclear: Whether .bordered or .plain might be better for menu bar popups specifically
   - Recommendation: Start with .inset style, test with 20+ items. Consider .plain if list is very long (50+ items).

3. **Row height for growth list**
   - What we know: Default is 44pt minimum, 28pt is standard for macOS tables
   - What's unclear: What feels right for folder name + growth amount display
   - Recommendation: Use defaultMinListRowHeight environment value to set 28-32pt for compact list.

4. **Settings window organization**
   - What we know: Should use toolbar or sidebar for multi-pane settings
   - What's unclear: Whether 5 tabs (Paths, Boundaries, Threshold, Debug, About) needs toolbar vs simple navigation
   - Recommendation: For 5 sections, use TabView with .tabViewStyle(.sidebarAdaptable) for native macOS appearance.
</open_questions>

<sources>
## Sources

### Primary (HIGH confidence)
- **User-created design guide**: `/Users/merlinkramer/dev/projects/prunr/documentation/macos_design_guide2.md` - Comprehensive HIG metrics and spacing standards
- **[Apple HIG - Layout](https://developer.apple.com/design/human-interface-guidelines/layout)** - Official layout guidelines
- **[Apple HIG - Settings](https://developer.apple.com/design/human-interface-guidelines/settings)** - Official settings window patterns
- **[Apple HIG - Lists and Tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables)** - Official list/table guidelines
- **[Apple HIG - Windows](https://developer.apple.com/design/human-interface-guidelines/windows)** - Official window patterns
- **[SwiftUI Settings Documentation](https://developer.apple.com/documentation/swiftui/settings)** - Official Settings scene API
- **[.listStyle(.inset(alternatesRowBackgrounds:))](https://developer.apple.com/documentation/swiftui/liststyle/inset(alternatesrowbackgrounds:))** - Official inset list style API

### Secondary (MEDIUM confidence)
- **[SwiftUI for Mac 2024](https://troz.net/post/2024/swiftui-mac-2024/)** (Aug 2024) - Current SwiftUI macOS patterns, verified against official docs
- **[Customizing SwiftUI Settings Window](https://medium.com/@clyapp/customizing-swiftui-settings-window-on-macos-4c47d0060ee4)** - Settings window customization techniques
- **[Nil Coalescing - Custom About Window](https://nilcoalescing.com/blog/FullyCustomAboutWindowForAMacAppInSwiftUI)** - About window implementation pattern
- **[SettingsAccess Library](https://github.com/orchetect/SettingsAccess)** - Community solution for macOS 13+ Settings keyboard shortcut issue
- **[Scenes types in SwiftUI Mac apps](https://nilcoalescing.com/blog/ScenesTypesInASwiftUIMacApp)** (May 2024) - Scene patterns verified against WWDC content
- **[Tailor macOS windows with SwiftUI - WWDC24](https://developer.apple.com/videos/play/wwdc2024/10148/)** - Official Apple window customization session

### Tertiary (LOW confidence - needs validation)
- None - all findings verified against user's design guide or official Apple documentation
</sources>

<metadata>
## Metadata

**Research scope:**
- Core technology: SwiftUI macOS UI patterns
- Ecosystem: Settings scene, List/Table views, window management
- Patterns: HIG-compliant spacing, standard layouts, macOS conventions
- Pitfalls: Spacing mistakes, wrong list styles, keyboard shortcuts

**Confidence breakdown:**
- Standard stack: HIGH - SwiftUI is well-documented, user's design guide is comprehensive
- Architecture: HIGH - based on official Apple patterns and WWDC sessions
- Pitfalls: HIGH - documented in user's guide, verified against common issues
- Code examples: HIGH - based on official SwiftUI APIs and user's metrics

**Research date:** 2025-01-11
**Valid until:** 2025-06-11 (6 months - SwiftUI/macOS patterns stable, new versions yearly)

**Note:** User's existing design guide (`documentation/macos_design_guide2.md`) was the primary source and is already comprehensive. This research focuses on SwiftUI-specific implementation patterns that complement the documented metrics.
</metadata>

---

*Phase: 06-popup-hig-redesign*
*Research completed: 2025-01-11*
*Ready for planning: yes*
