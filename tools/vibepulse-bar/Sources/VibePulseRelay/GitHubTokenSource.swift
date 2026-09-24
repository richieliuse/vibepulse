import Foundation

/// Reads a GitHub token and never logs it.
///
/// Injected environment, first non-blank of `GH_TOKEN`, `GITHUB_TOKEN`,
/// `TG_GITHUB_TOKEN`. Then the files `tokenserver._read_github_token` reads:
/// `~/.torget-github-token`, `<repoRoot>/.github-token`, and the first
/// `#define TG_GITHUB_TOKEN "..."` in `<repoRoot>/secrets.h` (invalid UTF-8
/// bytes in that header are dropped). Blank, missing, and unreadable sources
/// are skipped. No match returns nil. The process environment is not read.
public enum GitHubTokenSource {
    private static let environmentNames = ["GH_TOKEN", "GITHUB_TOKEN", "TG_GITHUB_TOKEN"]
    private static let secretDefine = try! NSRegularExpression(
        pattern: #"#\s*define\s+TG_GITHUB_TOKEN\s+"([^"]+)""#
    )

    public static func token(
        environment: [String: String],
        homeDirectory: URL,
        repoRoot: URL
    ) -> String? {
        for name in environmentNames {
            if let value = nonBlank(environment[name]) {
                return value
            }
        }
        let files = [
            homeDirectory.appendingPathComponent(".torget-github-token"),
            repoRoot.appendingPathComponent(".github-token"),
        ]
        for url in files {
            if let value = tokenFile(at: url) {
                return value
            }
        }
        return secretsToken(at: repoRoot.appendingPathComponent("secrets.h"))
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// UTF-8 token files. A file that cannot be read or decoded is skipped.
    private static func tokenFile(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return nonBlank(text)
    }

    private static func secretsToken(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = droppingInvalidUTF8(data)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = secretDefine.firstMatch(in: text, range: range),
              let capture = Range(match.range(at: 1), in: text) else { return nil }
        return nonBlank(String(text[capture]))
    }

    /// Python `read_text(encoding="utf-8", errors="ignore")`: drop bad bytes.
    private static func droppingInvalidUTF8(_ data: Data) -> String {
        var cursor = ByteCursor(data: data)
        var decoder = UTF8()
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(data.count)
        while true {
            let before = cursor.consumed
            switch decoder.decode(&cursor) {
            case let .scalarValue(scalar):
                scalars.append(scalar)
            case .emptyInput:
                return String(scalars)
            case .error:
                if cursor.consumed == before {
                    _ = cursor.next()
                }
            }
        }
    }
}

private struct ByteCursor: IteratorProtocol {
    let data: Data
    var index: Data.Index
    var consumed = 0

    init(data: Data) {
        self.data = data
        self.index = data.startIndex
    }

    mutating func next() -> UInt8? {
        guard index < data.endIndex else { return nil }
        let byte = data[index]
        index = data.index(after: index)
        consumed += 1
        return byte
    }
}
