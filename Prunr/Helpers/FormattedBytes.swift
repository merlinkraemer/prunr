import Foundation

/// Formats a byte count into a human-readable string (e.g. "1.2 GB", "450 MB").
func formattedBytes(_ bytes: Int64) -> String {
    let kb = Double(bytes) / 1_000
    let mb = kb / 1_000
    let gb = mb / 1_000
    let tb = gb / 1_000

    if abs(tb) >= 1 {
        return "\(String(format: "%.1f", tb)) TB"
    } else if abs(gb) >= 1 {
        return "\(String(format: "%.1f", gb)) GB"
    } else if abs(mb) >= 1 {
        return "\(String(format: "%.0f", mb)) MB"
    } else if abs(kb) >= 1 {
        return "\(String(format: "%.0f", kb)) KB"
    } else {
        return "\(bytes) B"
    }
}
