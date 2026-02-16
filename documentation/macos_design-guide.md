Perfect! Here's your comprehensive guide to native macOS menu bar popover hover states:

## 🎯 Quick Answers to Your Questions

### **Horizontal Inset**
**4-6 points** from the popover edge to where the blue highlight starts. This creates breathing room and matches native system behavior.

### **Corner Radius**
**6-8 points** (typically 6pt) — a subtle rounding that feels native without being aggressive.

### **Vertical Padding Inside Row**
**6 points** above and below the text within each row.

### **Spacing Between Rows**
**0 points** — rows touch each other, but the hover highlight inset creates visual separation.

### **Font**
- **Size**: **13pt** (system standard for menu bar)
- **Weight**: **Regular (400)** for normal items
- **Font Family**: **SF Pro** (system font, automatic in SwiftUI/Cocoa)

### **Icon-to-Text Spacing**
**8 points** exactly — this is Apple's standard spacing.

***

## 📐 Complete Row Anatomy (Standard 28pt Height)

```
Total height: 28pt
├─ Top inset: 4pt (from top of row to highlight start)
├─ Text vertical padding: 6pt above, 6pt below
└─ Bottom inset: 4pt (from bottom of row to highlight end)

Horizontal layout:
├─ Left edge: 8pt padding to icon
├─ Icon: 16×16pt (SF Symbols Medium)
├─ Icon-to-text: 8pt spacing
├─ Text: 13pt SF Pro Regular
├─ Right side: 8pt padding minimum
└─ Highlight inset: 4-6pt on all sides
```

***

## 🎨 Essential Design Guidelines for Your Menu Bar App

| Aspect | Value | Notes |
|--------|-------|-------|
| **Row Height** | 28pt | Standard; use 24pt (small) or 32pt (large) if needed |
| **Highlight Radius** | 6pt | Matches native system |
| **Highlight Inset** | 4-6pt | All sides |
| **Icon Size** | 16×16pt | SF Symbols at Medium scale |
| **Font** | SF Pro 13pt Regular | Automatic in SwiftUI |
| **Icon-Text Gap** | 8pt | Non-negotiable |
| **Popover Width** | 250-350pt | Responsive to content |
| **Transition Speed** | 150ms | Subtle fade for hover |
| **Dark Mode** | Full support | Test both themes |

***

## 🚀 Key Implementation Tips

1. **Hover highlight** uses system blue with ~15% opacity
2. **No gaps between rows** — they touch, but inset highlight creates separation visually
3. **Section headers** are 11pt semibold gray, 24pt height
4. **Keyboard shortcuts** display far right, 11pt gray, 8pt margin
5. **Disabled items** have 50% opacity, don't highlight on hover
6. **Checkmarks/icons** are 16×16pt right-aligned with 8pt margin
