import SwiftUI
import AppKit

enum MDBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulletList([String])
    case orderedList([String])
    case codeBlock(text: String, lang: String?)
    case quote(String)
    case rule
}

struct MarkdownPreviewView: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        ScrollableHosting(scrollFraction: $doc.scrollFraction) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(MarkdownParser.parse(doc.content).enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 60)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(headingFont(for: level))
                .fontWeight(level <= 2 ? .bold : .semibold)
                .padding(.top, level <= 2 ? 6 : 2)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(inline(text))
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundColor(.secondary)
                            .frame(width: 10, alignment: .center)
                        Text(inline(item))
                            .font(.system(size: 14))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .frame(width: 18, alignment: .trailing)
                        Text(inline(item))
                            .font(.system(size: 14))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .codeBlock(let text, _):
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case .quote(let text):
            Text(inline(text))
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 13)
                .padding(.vertical, 2)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: 3)
                }
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        do {
            return try AttributedString(
                markdown: s,
                options: .init(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )
        } catch {
            return AttributedString(s)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .system(size: 26)
        case 2: return .system(size: 21)
        case 3: return .system(size: 17)
        case 4: return .system(size: 15)
        case 5: return .system(size: 13)
        default: return .system(size: 12)
        }
    }
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Code fence
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("```") {
                        i += 1
                        break
                    }
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(text: code.joined(separator: "\n"), lang: lang.isEmpty ? nil : lang))
                continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.rule)
                i += 1
                continue
            }

            // Heading
            if let (level, text) = matchHeading(trimmed) {
                blocks.append(.heading(level: level, text: text))
                i += 1
                continue
            }

            // Bullet list
            if matchBullet(trimmed) != nil {
                var items: [String] = []
                while i < lines.count, let item = matchBullet(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    i += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            // Ordered list
            if matchOrdered(trimmed) != nil {
                var items: [String] = []
                while i < lines.count, let item = matchOrdered(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    i += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                var qLines: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(">") {
                        let stripped = t.dropFirst(t.hasPrefix("> ") ? 2 : 1)
                        qLines.append(String(stripped))
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.quote(qLines.joined(separator: "\n")))
                continue
            }

            // Paragraph: join consecutive non-blank, non-block lines
            var pLines: [String] = [line]
            i += 1
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if t.hasPrefix("```")
                    || matchHeading(t) != nil
                    || matchBullet(t) != nil
                    || matchOrdered(t) != nil
                    || t.hasPrefix(">")
                    || t == "---" || t == "***" || t == "___" {
                    break
                }
                pLines.append(lines[i])
                i += 1
            }
            blocks.append(.paragraph(pLines.joined(separator: "\n")))
        }
        return blocks
    }

    static func matchHeading(_ s: String) -> (Int, String)? {
        var level = 0
        var idx = s.startIndex
        while idx < s.endIndex && s[idx] == "#" && level < 6 {
            level += 1
            idx = s.index(after: idx)
        }
        guard level >= 1, idx < s.endIndex, s[idx] == " " else { return nil }
        let text = String(s[s.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    static func matchBullet(_ s: String) -> String? {
        guard s.count >= 2 else { return nil }
        let first = s.first!
        let second = s[s.index(after: s.startIndex)]
        if (first == "-" || first == "*" || first == "+") && second == " " {
            return String(s.dropFirst(2))
        }
        return nil
    }

    static func matchOrdered(_ s: String) -> String? {
        var idx = s.startIndex
        var hasDigit = false
        while idx < s.endIndex, let scalar = s[idx].unicodeScalars.first, CharacterSet.decimalDigits.contains(scalar) {
            hasDigit = true
            idx = s.index(after: idx)
        }
        guard hasDigit, idx < s.endIndex, s[idx] == "." else { return nil }
        let next = s.index(after: idx)
        guard next < s.endIndex, s[next] == " " else { return nil }
        return String(s[s.index(after: next)...])
    }
}
