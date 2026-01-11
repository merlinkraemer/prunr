# macOS Human Interface Guidelines - Design Metrics & Best Practices

## 1. Preferences & Settings Windows

### Organization & Structure
**Toolbar vs Sidebar approach:**[61]
- **Preference Style**: Use `.preference` style with `NSTabViewController` + toolbar for automatic layout
- **Expanded Style**: Traditional toolbar with centered title, large button icons with labels below
- **Automatic Style**: Default that determines style based on window structure

### Standard Dimensions
- **Example window size**: 370×250pt (common starting point)[59]
- **Toolbar buttons**: Now appear borderless at rest, with border on hover[61]
- **Title bar integration**: Use `fullSizeContentView` to extend content under title bar[61]

### Grouping & Organization[58]
- **Margin standard**: 20pt margin on left, right, and bottom sides
- **Spacing between controls**: Minimum 12pt, maximum 24pt (adjust for white space)
- **Separator padding**: 12pt above and below for Regular controls
- **Smaller controls**: Reduce separator spacing proportionally (6-8pt for Small/Mini)

---

## 2. Lists & Table Views

### Row Heights & Cell Layout
**macOS 11+ Sidebar Specifications:**[49]
| Size | Row Height | Symbol Size | Horizontal Spacing | Padding (L/R) |
|------|-----------|-------------|-------------------|---------------|
| Small | 24pt | 16×16pt | 17pt | 6pt |
| Large | 32pt | 24×24pt | 17pt | 6pt |

**Inset-Style Tables:**[49]
- 10pt vertical inset before first row and after last row
- Provides visual breathing room without excessive padding

### Cell Content Structure[17]
**Content hierarchy:**
- Primary information at start, supporting details follow
- Consistent text sizing: prominent for main content, lighter weight for secondary
- White space between elements without gaps

**Image/Icon standards:**
- Maintain consistent dimensions for icons and thumbnails across rows
- SF Symbols scale: 16pt (small), 24pt (large) [49]

**Data alignment:**[17]
- Text: Left-aligned with consistent line height
- Numbers: Right-aligned with matching decimal places
- Dates/Times: Adapted to user region (12/31/23 US, 31/12/23 EU, etc.)
- Status values: Use system colors and SF Symbols

### Selection States & Interaction
- Selection background: Edge-to-edge (fullWidth) or inset style[61]
- sourceList style: New appearance specifically for sidebar source lists[61]
- Automatic style resolution: Based on table configuration and context

---

## 3. Layout Guidelines & Spacing

### Core Spacing System[52]
Apple uses an 8-point increment system as foundation:
- **Base increment**: 8pt
- **Standard measurements**: 8pt, 16pt, 32pt for primary spacing
- **Layout hierarchy**: Standard margins and padding create natural visual paths

### Margin Standards
**Default margins:**[58]
- **Left/right/bottom**: 20pt for standard windows
- **Group boxes with small controls**: May use narrower margins (check content)

**Spacing between related elements:**[58]
- **Minimum spacing**: 12pt between logical groups
- **Standard spacing**: 16-20pt depending on device
- **Maximum spacing**: 24pt (only for increased white space)

### Padding in UI Components[52]
- **Content separation**: Creates breathing room while maintaining relationships
- **Touch targets**: Minimum 44×44pt for touchable elements
- **Interactive elements**: Adequate padding creates comfortable touch targets
- **Visual grouping**: Consistent padding shows relationships while keeping elements distinct

### Safe Areas & Edge Considerations
- Always respect safe areas for content placement[61]
- Safe Area Layout Guide available in Interface Builder
- Use `.fullSizeContentView` only when intentionally extending under title bar

---

## 4. Popovers

### Usage vs Windows[60]
**When to use popovers:**
- Temporary, contextual information
- Small supplementary content
- Anchored to a UI element
- Should not obscure primary content flow

**Default sizing behavior:**[60]
- System provides default size based on device and available space
- Use `preferredContentSize` property to control dimensions
- Typical width range: 300-400pt (common for most use cases)

### Content Sizing & Padding[60]
**Recommended dimensions:**
- Typical width: 300-400pt
- **Maximum width**: ~600pt (beyond this, system may compress content)
- **Self-sizing**: Use Auto Layout with `systemLayoutSizeFitting(layoutFittingCompressedSize)`

**Padding/Margins:**
- Content should have consistent padding from edges
- Allow sufficient space for text wrapping and interaction
- Test across multiple content lengths to ensure readability

### Anchor Point Behavior
- Popovers spring from their invoking element
- Arrow/pointer directs attention to source
- Automatically adjust position if insufficient space at preferred location
- Avoid multiple simultaneous popovers (clutters interface)[12]

---

## 5. File Open & Save Dialogs

### Sizing & State[81]
**Default behavior:**
- Resizable by user (drag from bottom-right corner)
- Intended to remember previous user size[81]
- **Big Sur caveat**: Known bug where size reset occurs (fixed in 11.2+)[86]

**Reset capability:**
- Use terminal command: `defaults delete -app [AppName] NSNavPanelExpandedSizeForOpenMode`
- For save dialogs: `defaults delete -app [AppName] NSNavPanelExpandedSizeForSaveMode`[81]

### Standard Implementation
- Use native macOS file chooser dialog when possible
- Don't artificially constrain dialog size
- Test across different screen sizes and aspect ratios

---

## 6. About Windows

### Standard Layout Pattern[67]
Essential elements (in order):
1. **Application icon** (typically 64-128pt)
2. **App name** (prominent, large font)
3. **Version & build information** (secondary text)
4. **Copyright notice** (with current year)
5. **Optional: Developer/company link** (clickable hyperlink)

### Recommended Dimensions[67]
- **Minimum window**: 400pt width, 260pt height
- **Content padding**: Standard 20pt margins
- **Icon size**: 80pt is common for about windows
- **Text hierarchy**: Title (larger), body text, copyright (smaller)

### Information to Display
- Application name and icon[73]
- Version number (and build if relevant)
- Copyright: © YYYY Company Name[67]
- Optional: Credits link, website URL[67]
- Optional: Acknowledgments or special thanks

---

## 7. Inspector Panels & Sidebars

### Sidebar Sizing[89], [90]
**Typical width ranges:**
- **Minimum width**: 150-220pt (allows for some content, prevents over-compression)
- **Ideal width**: 300pt (standard inspector width)
- **Maximum width**: 380-600pt (depends on content complexity)

**Key principle**: Constraint the detail view minimum width, not the sidebar maximum—allows natural growth until detail view's minimum is reached[89]

### Inspector Implementation[99]
**WWDC-recommended defaults:**
- min: 200pt
- ideal: 300pt
- max: 400pt

**Modifiers:**
- `inspectorColumnWidth(min:ideal:max:)` - flexible width with persistence across launches
- `inspectorColumnWidth(_:)` - fixed width (no resizing)

### Sidebar with Full-Height Layout
- Set `allowsFullHeightLayout` on sidebar `NSSplitViewItem`[61]
- Use when sidebar is typically collapsed or needs more vertical space
- Modern macOS design: Full-height sidebars are standard[61]

---

## 8. Toolbar Guidelines

### Item Organization[74], [80]
**Grouping principles:**
- Group related items together
- Separate sections with separators or flexible space items[74]
- Limit sidebar toolbar items to maximum 2 items[80]
- Move secondary actions to overflow menu if crowded

**Spacing methods:**
- Space Item: Fixed-width spacing between items
- Flexible Space Item: Expands to maximum available space
- Separator: Visual divider between groups[74]

### Item Sizing & Display[79]
**Toolbar button styles:**
- Bordered property: Provides automatic enabling/disabled support
- Title property: Configure string-based buttons instead of icon-only
- Regular, Small, Mini sizes available

**Control sizing:**
- macOS typically uses Regular size (default)
- Small/Mini for space-constrained areas (tool palettes, HUDs, inspector sidebars)[58]
- Avoid mixing sizes within same toolbar/pane

### Title Bar Integration[61]
- New preference style complements toolbar-based navigation
- Automatic scaling with toolbar items
- Unified appearance with newer design system

---

## 9. Split Views & Navigation

### Column Width Configuration[95], [99]
**NavigationSplitView modifiers:**
```
.navigationSplitViewColumnWidth(200)  // Fixed width
.navigationSplitViewColumnWidth(min: 300, ideal: 400, max: 500)  // Flexible
```

**Default proportions:**[101]
- Primary pane: ~1/3 of screen width
- Secondary pane: ~2/3 of screen width
- Adjustable per application needs

### Split View Styles[95]
- **automatic**: Context-specific (default)
- **balanced**: Shows leading columns side-by-side with reduced detail view
- Other variants for specific layout needs

---

## 10. Control Sizes & Button Specifications

### Control Size Options[88]
macOS supports four control sizes:
- **Regular**: Default, full-featured appearance
- **Small**: Compact version for space-conscious layouts
- **Mini**: Noticeably smaller than small, for extreme space constraints
- **Large**: Emphasis, prominent actions (newer specification)

**Usage guidelines:**[58]
- Primary choice: Always Regular size first
- Smaller sizes: Only when space is premium (tool palettes, toolbars, HUDs, inspector sidebars)
- Avoid mixing multiple sizes in same container

### Button Hit Targets[40]
- **Minimum target**: 44pt × 44pt for reliable interaction
- Apply to interactive elements across all input methods
- Maintain adequate padding around clickable areas

---

## 11. Text & Typography Spacing

### Line Height Standards[114]
**Readability metrics:**
- **Ideal line height**: 1.5-1.6× font size
- **Optimal line length**: 60-80 characters
- **Shorter lines** (30 chars): Reduce line height to 1.3×
- **Longer lines** (80+ chars): Increase line height to 1.5× or more

### Paragraph Spacing[106]
**SwiftUI modifiers:**
- `listRowSpacing(_:)` - Adjust vertical space between adjacent list rows
- `listSectionSpacing(_:)` - Adjust space between list sections
- Can be applied globally or to specific sections

### Icon & Symbol Sizing[107], [49]
**SF Symbols standards:**
- Small sidebar: 16pt × 16pt
- Large sidebar: 24pt × 24pt
- Use font weight adjustments for visual emphasis
- Customize size with `.font(.system(size:weight:))`

---

## Summary: Key Metrics Reference

| Component | Metric | Value |
|-----------|--------|-------|
| **Margins** | Standard | 20pt |
| **Spacing** | Minimum | 12pt |
| **Spacing** | Standard | 16-20pt |
| **Spacing** | Maximum | 24pt |
| **Row Height** | Small sidebar | 24pt |
| **Row Height** | Large sidebar | 32pt |
| **Icon Size** | Small | 16×16pt |
| **Icon Size** | Large | 24×24pt |
| **Popover Width** | Typical | 300-400pt |
| **Popover Width** | Maximum | ~600pt |
| **Inspector Width** | Min/Ideal/Max | 200/300/400pt |
| **About Window** | Minimum | 400×260pt |
| **Sidebar Spacing** | Horizontal | 17pt |
| **Sidebar Padding** | Edge | 6pt |
| **Inset Table** | Vertical inset | 10pt (top/bottom) |
| **Touch Target** | Minimum | 44×44pt |
| **Line Height** | Multiplier | 1.5-1.6× |

---

## Implementation Tips

1. **Always test** across different window sizes and resolutions
2. **Use Auto Layout** for responsive spacing that adapts to content
3. **Respect safe areas** to accommodate system UI elements
4. **Reference system fonts** and colors for consistency
5. **Follow platform conventions** for control placement and behavior
6. **Test accessibility** features like larger text sizes
7. **Consider appearance modes** (light/dark) in design decisions
8. **Use SF Symbols** for consistent iconography across your app

---

## Additional Resources

- [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
- [WWDC Videos](https://developer.apple.com/videos/) - Search "macOS design"
- [SwiftUI Documentation](https://developer.apple.com/documentation/swiftui)
- [AppKit Documentation](https://developer.apple.com/documentation/appkit)
