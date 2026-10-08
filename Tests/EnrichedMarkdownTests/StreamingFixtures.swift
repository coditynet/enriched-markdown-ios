import UIKit
@testable import EnrichedMarkdown

/// LLM-style answers for the streaming tests: every block type an answer
/// mixes, in the order a model writes them.
enum StreamingFixtures {
    static let answer = """
    # Photosynthese einfach erklärt

    Pflanzen wandeln **Lichtenergie** in *chemische Energie* um. Dabei entsteht \
    aus `CO₂` und Wasser Traubenzucker — und als Nebenprodukt Sauerstoff. Ein \
    Kilo Äpfel kostet übrigens 3$ und eine Tüte 5 $ pro Stück.

    ## Die zwei Phasen

    1. **Lichtreaktion**: findet in den *Thylakoiden* statt.
       - Wasser wird gespalten
       - ATP und NADPH entstehen
    2. **Calvin-Zyklus**: im Stroma wird CO₂ fixiert.

    > **Merke:** Ohne Licht keine Lichtreaktion — der Calvin-Zyklus läuft \
    > aber auch kurz im Dunkeln weiter.

    ### Vergleich

    | Phase | Ort | Produkte |
    |---|---|---|
    | Licht | Thylakoid | ATP, NADPH, O₂ |
    | Calvin | Stroma | Glucose |

    - [x] Begriffe gelernt
    - [ ] Aufgaben gemacht

    ```python
    def bilanz(co2, h2o):
        # 6 CO2 + 6 H2O -> C6H12O6 + 6 O2
        return min(co2, h2o) / 6
    ```

    ---

    Mehr dazu findest du im [Lehrbuch](https://example.com/bio?kapitel=3) oder \
    bei ~~Wikipedia~~ deiner Lehrkraft. Viel Erfolg!
    """

    /// About `count` characters of `answer` repeated, sections renumbered.
    static func longAnswer(characters count: Int) -> String {
        var result = ""
        var section = 1
        while result.count < count {
            result += answer.replacingOccurrences(of: "# Photosynthese", with: "# \(section). Photosynthese")
            result += "\n\n"
            section += 1
        }
        return result
    }

    /// Prefixes of `markdown` as a model streams it: a few characters at a
    /// time, deterministically.
    static func chunks(of markdown: String, sizes: [Int] = [3, 7, 4, 11, 5, 2, 9]) -> [String] {
        var prefixes: [String] = []
        var index = markdown.startIndex
        var step = 0
        while index < markdown.endIndex {
            index = markdown.index(index, offsetBy: sizes[step % sizes.count], limitedBy: markdown.endIndex)
                ?? markdown.endIndex
            prefixes.append(String(markdown[..<index]))
            step += 1
        }
        return prefixes
    }

    static func config() -> MarkdownStyleConfig {
        MarkdownStyleConfig.baseline()
    }
}
