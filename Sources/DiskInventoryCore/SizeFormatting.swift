import Foundation

/// Formatting of sizes and percentages.
public enum SizeFormatting {
    // ByteCountFormatter (the system formatter, also used by the Finder) with decimal units.
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false   // "0 bytes" instead of "Zero KB"
        return f
    }()

    public static func string(forBytes bytes: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: bytes))
    }

    public static func percentString(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "–" }
        let pct = fraction * 100
        if pct > 0 && pct < 0.1 { return "<0.1 %" }
        return String(format: "%.1f %%", pct)
    }
}
