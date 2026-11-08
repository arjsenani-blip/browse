import Foundation
import WebKit

/// Builds the JavaScript that injects element-hiding CSS into a page.
///
/// Run it at document start in an isolated content world (`CosmeticScript.contentWorldName`) so the
/// page can't observe or tamper with the script's globals; the `<style>` element itself lives in the
/// shared DOM. Content rules already hide most selectors; this covers rules WebKit can't express.
public enum CosmeticScript {
    public static let contentWorldName = "AegisCosmetic"

    /// The isolated world the script should run in.
    @MainActor
    public static var contentWorld: WKContentWorld { .world(name: contentWorldName) }

    /// One CSS rule per selector so a single selector WebKit doesn't understand can't disable the rest.
    public static func css(for selectors: [String]) -> String {
        var css = ""
        for selector in selectors {
            css += selector
            css += "{display:none!important}\n"
        }
        return css
    }

    /// JavaScript injecting the CSS for `host`, or `nil` when nothing applies.
    public static func source(for host: String, index: CosmeticIndex, mode: CosmeticIndex.Mode = .supplement) -> String? {
        let selectors = index.selectors(for: host, mode: mode)
        guard !selectors.isEmpty else { return nil }
        var literal = ""
        appendJSONString(css(for: selectors), to: &literal)
        return """
        (() => {
          const css = \(literal);
          const install = () => {
            const style = document.createElement('style');
            style.setAttribute('data-aegis', '');
            style.textContent = css;
            (document.head || document.documentElement).appendChild(style);
          };
          if (document.documentElement) { install(); }
          else { document.addEventListener('readystatechange', install, { once: true }); }
        })();
        """
    }
}
