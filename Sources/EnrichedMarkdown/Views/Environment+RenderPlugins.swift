import SwiftUI

private struct MarkdownRenderPluginsKey: EnvironmentKey {
    static let defaultValue: [any MarkdownRenderPlugin] = []
}

package extension EnvironmentValues {
    /// Populated by `.markdownRenderPlugin(_:)` and optional modules' public
    /// modifiers (`.markdownLaTeX()`).
    var markdownRenderPlugins: [any MarkdownRenderPlugin] {
        get { self[MarkdownRenderPluginsKey.self] }
        set { self[MarkdownRenderPluginsKey.self] = newValue }
    }
}

public extension View {
    /// Installs `plugin` for the markdown views below, consulted before the
    /// built-in renderers and before plugins installed further out, so the
    /// innermost claim wins.
    func markdownRenderPlugin(_ plugin: some MarkdownRenderPlugin) -> some View {
        transformEnvironment(\.markdownRenderPlugins) { plugins in
            plugins.insert(plugin, at: 0)
        }
    }
}
