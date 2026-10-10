import Foundation

/// Number and time formatting. Speeds keep enough digits for any Mac (0.5 to
/// 16+ graphs/s); estimates are marked "≈" by the caller.
enum Format {
    /// Graphs/s: 2 decimals below 10, 1 below 100, else none ("0.58", "5.21", "16.2").
    static func rate(_ v: Double) -> String {
        let digits = v < 10 ? 2 : v < 100 ? 1 : 0
        return v.formatted(.number.precision(.fractionLength(digits)))
    }

    /// "399 XTM", "126 XTM", "4.1 XTM", "0.42 XTM": none at 100 or more, 1 decimal at 1 or more, else 2 significant digits.
    static func xtm(_ v: Double) -> String {
        let a = abs(v)
        if a == 0 { return "0 XTM" }
        if a >= 99.95 { return v.formatted(.number.precision(.fractionLength(0))) + " XTM" }
        if a >= 1 { return v.formatted(.number.precision(.fractionLength(1))) + " XTM" }
        return v.formatted(.number.precision(.significantDigits(2))) + " XTM"
    }

    /// "$0.68"; below a cent, 2 significant digits ("$0.0042").
    static func usd(_ v: Double) -> String {
        let a = abs(v)
        if a > 0 && a < 0.01 { return v.formatted(.currency(code: "USD").precision(.significantDigits(2))) }
        return v.formatted(.currency(code: "USD"))
    }

    /// "7.6 W", "20 W": 1 decimal below 10.
    static func watts(_ w: Double) -> String {
        w.formatted(.number.precision(.fractionLength(w < 9.95 ? 1 : 0))) + " W"
    }

    /// "2.7 J" per graph: 1 decimal below 10.
    static func joules(_ j: Double) -> String {
        j.formatted(.number.precision(.fractionLength(j < 9.95 ? 1 : 0))) + " J"
    }

    /// "1,296 MHz"
    static func mhz(_ m: Double) -> String { Int(m.rounded()).formatted() + " MHz" }

    /// Memory sizes in binary units, as macOS shows them ("5.3 GB", "24 GB"
    /// for 24 GiB): one decimal below 10 GB, dropped when it is 0.
    static func bytes(_ b: UInt64) -> String {
        let gb = Double(b) / Double(1 << 30)
        if gb < 1 { return "\(Int((Double(b) / Double(1 << 20)).rounded())) MB" }
        if gb >= 9.95 { return "\(Int(gb.rounded())) GB" }
        let r = (gb * 10).rounded() / 10
        return r == r.rounded() ? "\(Int(r)) GB" : r.formatted(.number.precision(.fractionLength(1))) + " GB"
    }

    /// "63%"; one decimal below 10% ("1.0%"). `fraction` is 0...1.
    static func percent(_ fraction: Double) -> String {
        let p = fraction * 100
        return p < 9.95 ? p.formatted(.number.precision(.fractionLength(1))) + "%" : "\(Int(p.rounded()))%"
    }

    /// "2 h 14 min", "14 min", "40 s", "3 d 2 h".
    static func duration(_ s: TimeInterval) -> String {
        let total = Int(max(0, s).rounded())
        if total < 60 { return "\(total) s" }
        let m = total / 60
        if m < 60 { return "\(m) min" }
        let h = m / 60
        if h < 48 { return m % 60 == 0 ? "\(h) h" : "\(h) h \(m % 60) min" }
        return h % 24 == 0 ? "\(h / 24) d" : "\(h / 24) d \(h % 24) h"
    }

    /// Short local time, "2:30 PM".
    static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}
