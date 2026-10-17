import AppKit

enum TextWidth {

    static let cellPadding: CGFloat = 24
    static let maxTitle: CGFloat = 320

    static func of(_ text: String, size: CGFloat = NSFont.systemFontSize) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size)
        return (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    static func widest(_ texts: [String], padding: CGFloat = cellPadding) -> CGFloat? {
        guard let widest = texts.map({ of($0) }).max() else { return nil }
        return widest + padding
    }
}
