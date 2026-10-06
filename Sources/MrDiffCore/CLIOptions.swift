import Foundation

/// コマンドラインのつまみの一覧。**`--help` とシェル補完が、同じ表を読む**（片方だけ古くなるのを防ぐ）。
public struct CLIOption {
    /// `--help` に出す形（`--tolerance=N`）。
    public let usage: String
    /// 説明の文言のキー。
    public let helpKey: String
    /// 補完に出す語。値を取るつまみは `=` までを入れる（`--tolerance=`）。
    public let words: [String]
    /// `=` の後に入る値の候補（無ければ空）。
    public let values: [String]
}

public enum CLIOptions {
    public static let all: [CLIOption] = [
        .init(usage: "--exit-code", helpKey: "help.exit_code", words: ["--exit-code"], values: []),
        .init(usage: "--quiet, -q", helpKey: "help.quiet", words: ["--quiet", "-q"], values: []),
        .init(usage: "--oneline", helpKey: "help.oneline", words: ["--oneline"], values: []),
        .init(usage: "--relative", helpKey: "help.relative", words: ["--relative"], values: []),
        .init(usage: "--show-secrets", helpKey: "help.show_secrets", words: ["--show-secrets"], values: []),
        .init(usage: "--json", helpKey: "help.json", words: ["--json"], values: []),
        .init(usage: "--tolerance=N", helpKey: "help.tolerance", words: ["--tolerance="], values: []),
        .init(usage: "--offset=dx,dy", helpKey: "help.offset", words: ["--offset="], values: []),
        .init(usage: "--ignore-alpha", helpKey: "help.ignore_alpha", words: ["--ignore-alpha"], values: []),
        .init(usage: "--text", helpKey: "help.text", words: ["--text"], values: []),
        .init(usage: "--color=auto|always|never", helpKey: "help.color", words: ["--color="],
              values: ["auto", "always", "never"]),
        .init(usage: "--no-pager", helpKey: "help.no_pager", words: ["--no-pager"], values: []),
        .init(usage: "--clipboard", helpKey: "help.clipboard", words: ["--clipboard"], values: []),
        .init(usage: "--site <https://base> <dir>", helpKey: "help.site", words: ["--site"], values: []),
        .init(usage: "--ssh <dir> <host:path>", helpKey: "help.ssh", words: ["--ssh"], values: []),
        .init(usage: "--completions bash|zsh|fish", helpKey: "help.completions", words: ["--completions"],
              values: ["bash", "zsh", "fish"]),
        .init(usage: "--lang=en|ja", helpKey: "help.lang", words: ["--lang="], values: ["en", "ja"]),
        .init(usage: "--version", helpKey: "help.version", words: ["--version", "-V"], values: []),
        .init(usage: "--help", helpKey: "help.help", words: ["--help", "-h"], values: []),
    ]
}

/// シェル補完のスクリプトを作る。`mrdiff --completions zsh` が標準出力へ出す。
/// 説明の文言は `--help` と同じ（`t()` を通す＝いまの言語）。
public enum Completions {
    public static let shells = ["bash", "zsh", "fish"]

    public static func script(for shell: String) -> String? {
        switch shell {
        case "zsh": return zsh()
        case "bash": return bash()
        case "fish": return fish()
        default: return nil
        }
    }

    // MARK: zsh

    private static func zsh() -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "'", with: "'\\''")
             .replacingOccurrences(of: "[", with: "\\[")
             .replacingOccurrences(of: "]", with: "\\]")
        }
        var lines = ["#compdef mrdiff", "", "_arguments -s \\"]
        for o in CLIOptions.all {
            let doc = esc(t(o.helpKey))
            for w in o.words {
                if o.values.isEmpty {
                    lines.append("  '\(w)[\(doc)]' \\")
                } else if w.hasSuffix("=") {
                    lines.append("  '\(w)[\(doc)]:value:(\(o.values.joined(separator: " ")))' \\")
                } else {
                    // `--completions zsh` のように、空白で区切って値を取るもの
                    lines.append("  '\(w)[\(doc)]:shell:(\(o.values.joined(separator: " ")))' \\")
                }
            }
        }
        lines.append("  '*:file:_files'")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: bash

    private static func bash() -> String {
        let all = CLIOptions.all.flatMap(\.words).joined(separator: " ")
        var cases = ""
        // `=` で語を分けない設定の bash では、`--color=a` が 1 語で来る。値を、その語の続きとして補う。
        var whole = ""
        for o in CLIOptions.all where !o.values.isEmpty {
            for w in o.words where w.hasSuffix("=") {
                whole += "    \(w)*) COMPREPLY=( $(compgen -P \"\(w)\" -W \"\(o.values.joined(separator: " "))\" -- \"${cur#\(w)}\") ); return ;;\n"
            }
        }
        for o in CLIOptions.all where !o.values.isEmpty {
            for w in o.words {
                let name = w.hasSuffix("=") ? String(w.dropLast()) : w
                cases += "    \(name)) COMPREPLY=( $(compgen -W \"\(o.values.joined(separator: " "))\" -- \"$cur\") ); return ;;\n"
            }
        }
        return """
        # bash completion for mrdiff
        _mrdiff() {
          local cur="${COMP_WORDS[COMP_CWORD]}" prev="${COMP_WORDS[COMP_CWORD-1]}" prev2=""
          [ "$COMP_CWORD" -ge 2 ] && prev2="${COMP_WORDS[COMP_CWORD-2]}"
          case "$cur" in
        \(whole)  esac
          # `--color=` and the word after it: bash splits on `=`
          if [ "$prev" = "=" ]; then prev="$prev2"; elif [ "$cur" = "=" ]; then cur=""; fi
          case "$prev" in
        \(cases)  esac
          if [[ "$cur" == -* ]]; then
            COMPREPLY=( $(compgen -W "\(all)" -- "$cur") )
            [[ "${COMPREPLY[0]}" == *= ]] && compopt -o nospace 2>/dev/null
          else
            COMPREPLY=( $(compgen -f -- "$cur") )
          fi
        }
        complete -F _mrdiff mrdiff

        """
    }

    // MARK: fish

    private static func fish() -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "\\'") }
        var lines = ["# fish completion for mrdiff"]
        for o in CLIOptions.all {
            var spec = "complete -c mrdiff"
            for w in o.words {
                let bare = w.hasSuffix("=") ? String(w.dropLast()) : w
                if bare.hasPrefix("--") { spec += " -l \(bare.dropFirst(2))" }
                else if bare.hasPrefix("-") { spec += " -s \(bare.dropFirst(1))" }
            }
            if !o.values.isEmpty { spec += " -x -a '\(o.values.joined(separator: " "))'" }
            else if o.words.contains(where: { $0.hasSuffix("=") }) { spec += " -x" }
            spec += " -d '\(esc(t(o.helpKey)))'"
            lines.append(spec)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
