import Foundation

/// Output of `FilterListConverter.convert(_:)`.
public struct ConversionResult: Sendable {
    /// WebKit content-rule-list JSON arrays, each with at most `maxRulesPerList` rules.
    /// Network lists come first, then cosmetic lists.
    public var lists: [String]
    /// Total rules across `lists` (exceptions repeated in each network list are counted each time).
    public var ruleCount: Int
    public var networkRuleCount: Int
    public var cosmeticRuleCount: Int
    /// Source filter lines that produced at least one rule (or index entry).
    public var convertedFilterCount: Int
    /// Source filter lines that were skipped, by reason.
    public var skipped: [SkipReason: Int]
    /// Element-hiding data for `CosmeticScript`.
    public var cosmetic: CosmeticIndex

    /// Domain → CSS that content rules couldn't express (inject via `CosmeticScript`).
    public var cosmeticCSSByDomain: [String: String] { cosmetic.cosmeticCSSByDomain }
    public var totalSkipped: Int { skipped.values.reduce(0, +) }
}

/// Converts Adblock Plus / uBlock Origin filter syntax into WebKit content-rule-list JSON.
///
/// ## List layout and exceptions
/// `ignore-previous-rules` only affects earlier rules in the *same* list, so:
/// - **Network lists**: `[block rules…] + [all exception rules] + [$important block rules]`.
///   When block rules exceed one list, they're split into chunks and the full exception and
///   `$important` tail is repeated in every chunk (so exceptions always see every block rule).
/// - **Cosmetic lists** (separate from network so they compile/cache independently):
///   `[generic hides (batched)] + [generic hides with domain exceptions (unless-domain)] +
///   [ignore for $generichide domains] + [domain-specific hides (if-domain)] +
///   [ignore for $elemhide / $document domains]`. The ordering makes `$generichide` cancel
///   only the generic rules.
/// - `$domain=a.com|~sub.a.com` (mixed include/exclude, which WebKit forbids in one trigger) becomes
///   a block rule with `if-domain` followed immediately by an `ignore-previous-rules` twin with
///   the excluded subdomains in `if-domain`.
/// - Domain-specific cosmetic rules with mixed include/exclude go to `CosmeticIndex` for script injection.
public enum FilterListConverter {
    public static let maxRulesPerList = 150_000
    /// Generic selectors joined per `css-display-none` rule.
    public static let selectorsPerRule = 250

    public static func convert(_ text: String, maxRulesPerList: Int = FilterListConverter.maxRulesPerList) -> ConversionResult {
        var builder = Builder()
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })

        // Pass 1: collect $badfilter targets.
        var badfilters = Set<String>()
        for raw in lines where raw.contains("badfilter") {
            let line = trim(raw)
            if let key = badfilterTarget(line) { badfilters.insert(key) }
        }

        // Pass 2: convert.
        for raw in lines {
            let line = trim(raw)
            if line.isEmpty || line.hasPrefix("!") || (line.hasPrefix("[") && line.hasSuffix("]")) { continue }
            if !badfilters.isEmpty, badfilters.contains(line) || line.contains("badfilter") {
                builder.skip(.badfilter)
                continue
            }
            if let cosmetic = splitCosmetic(line) {
                builder.addCosmetic(domains: cosmetic.domains, marker: cosmetic.marker, body: cosmetic.body)
            } else {
                builder.addNetwork(line)
            }
        }
        return builder.finish(maxRulesPerList: max(2, maxRulesPerList))
    }

    // MARK: - Line helpers

    static func trim(_ s: Substring) -> String {
        var sub = s
        while let f = sub.first, f == " " || f == "\t" { sub.removeFirst() }
        while let l = sub.last, l == " " || l == "\t" { sub.removeLast() }
        return String(sub)
    }

    /// The text of the rule a `$badfilter` line disables.
    static func badfilterTarget(_ line: String) -> String? {
        guard let dollar = line.lastIndex(of: "$") else { return nil }
        let options = line[line.index(after: dollar)...].split(separator: ",")
        guard options.contains(where: { $0 == "badfilter" }) else { return nil }
        let kept = options.filter { $0 != "badfilter" }
        let pattern = String(line[..<dollar])
        return kept.isEmpty ? pattern : pattern + "$" + kept.joined(separator: ",")
    }

    enum CosmeticMarker: String, CaseIterable {
        case hide = "##", hideException = "#@#"
        case extended = "#?#", extendedException = "#@?#"
        case snippet = "#$#", snippetException = "#@$#"
        case script = "#%#", scriptException = "#@%#"
    }

    private static let markersByLength: [CosmeticMarker] =
        CosmeticMarker.allCases.sorted { $0.rawValue.utf8.count > $1.rawValue.utf8.count }

    static func splitCosmetic(_ line: String) -> (domains: String, marker: CosmeticMarker, body: String)? {
        let u = Array(line.utf8)
        var i = 0
        while i < u.count {
            if u[i] == UInt8(ascii: "#") {
                for marker in markersByLength {
                    let m = Array(marker.rawValue.utf8)
                    guard i + m.count <= u.count, Array(u[i..<(i + m.count)]) == m else { continue }
                    // Domain part must look like a domain list, otherwise it's a URL pattern with '#'.
                    let domainBytes = u[0..<i]
                    let valid = domainBytes.allSatisfy { b in
                        (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z")) || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
                            || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")) || b == UInt8(ascii: ".")
                            || b == UInt8(ascii: "-") || b == UInt8(ascii: "~") || b == UInt8(ascii: ",")
                            || b == UInt8(ascii: "*") || b == UInt8(ascii: "_") || b == UInt8(ascii: ":")
                            || b >= 0x80
                    }
                    guard valid else { return nil }
                    return (String(decoding: domainBytes, as: UTF8.self), marker,
                            String(decoding: u[(i + m.count)...], as: UTF8.self))
                }
            }
            i += 1
        }
        return nil
    }

    static let proceduralPseudos = [
        ":has-text(", ":contains(", ":-abp-", ":xpath(", ":upward(", ":remove(", ":style(",
        ":matches-css", ":min-text-length(", ":watch-attr(", ":nth-ancestor(", ":matches-path(",
        ":matches-attr(", ":matches-prop(", ":remove-attr(", ":remove-class(", ":others(",
        ":if(", ":if-not(", ":shadow", ":matches-media(", ":spath(",
    ]

    static func validateSelector(_ selector: String) -> SkipReason? {
        if selector.isEmpty { return .invalidSelector }
        let lower = selector.lowercased()
        for p in proceduralPseudos where lower.contains(p) { return .proceduralCosmetic }
        var paren = 0, bracket = 0
        var quote: UInt8? = nil
        var escaped = false
        for b in selector.utf8 {
            if escaped { escaped = false; continue }
            if b == UInt8(ascii: "\\") { escaped = true; continue }
            if let q = quote {
                if b == q { quote = nil }
                continue
            }
            switch b {
            case UInt8(ascii: "\""), UInt8(ascii: "'"): quote = b
            case UInt8(ascii: "("): paren += 1
            case UInt8(ascii: ")"): paren -= 1; if paren < 0 { return .invalidSelector }
            case UInt8(ascii: "["): bracket += 1
            case UInt8(ascii: "]"): bracket -= 1; if bracket < 0 { return .invalidSelector }
            case UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: ";"): return .invalidSelector
            default: break
            }
        }
        if paren != 0 || bracket != 0 || quote != nil { return .invalidSelector }
        return nil
    }

    // MARK: - Builder

    enum ABPType: String, CaseIterable {
        case script, image, stylesheet, font, media, xhr, subdocument, document, popup, ping, websocket, other

        var appleType: String? {
            switch self {
            case .script: "script"
            case .image: "image"
            case .stylesheet: "style-sheet"
            case .font: "font"
            case .media: "media"
            case .xhr: "fetch"
            case .popup: "popup"
            case .ping: "ping"
            case .websocket: "websocket"
            case .other: "other"
            case .subdocument, .document: nil
            }
        }

        static func named(_ name: Substring) -> ABPType? {
            switch name {
            case "script": .script
            case "image", "img": .image
            case "stylesheet", "css": .stylesheet
            case "font": .font
            case "media": .media
            case "xmlhttprequest", "xhr": .xhr
            case "subdocument", "frame": .subdocument
            case "document", "doc": .document
            case "popup": .popup
            case "ping", "beacon": .ping
            case "websocket": .websocket
            case "other", "object", "object-subrequest": .other
            default: nil
            }
        }

        /// Types implied when a filter names none (ABP excludes top-level documents and popups).
        static let defaults: Set<ABPType> = [.script, .image, .stylesheet, .font, .media, .xhr, .subdocument, .ping, .websocket, .other]
    }

    static let defaultSubresourceTypes = ["image", "style-sheet", "script", "font", "media", "fetch", "ping", "websocket", "other", "svg-document"]

    struct DomainSet {
        var includes: [String] = []
        var excludes: [String] = []
        var droppedReason: SkipReason? = nil
        var droppedInclude = false
    }

    static func parseDomains<S: StringProtocol>(_ parts: [S]) -> DomainSet {
        var set = DomainSet()
        for part in parts {
            var d = part.trimmingCharacters(in: .whitespaces).lowercased()
            if d.isEmpty || d == "*" { continue }
            let negated = d.hasPrefix("~")
            if negated { d.removeFirst() }
            if d.hasSuffix(".") { d.removeLast() }
            var reason: SkipReason? = nil
            if d.hasSuffix(".*") || d.contains("*") || d.contains("/") { reason = .entityDomain }
            else if d.utf8.contains(where: { $0 >= 0x80 }) { reason = .nonASCII }
            else if d.isEmpty { reason = .malformed }
            if let reason {
                set.droppedReason = reason
                if !negated { set.droppedInclude = true }
                continue
            }
            if negated { set.excludes.append(d) } else { set.includes.append(d) }
        }
        return set
    }

    static func isSubdomain(_ d: String, of parent: String) -> Bool {
        d == parent || d.hasSuffix("." + parent)
    }

    /// `||host^` / `||host` / `||host/` → host.
    static func plainHost(_ pattern: Substring) -> String? {
        guard pattern.hasPrefix("||") else { return nil }
        var p = pattern.dropFirst(2)
        if p.hasSuffix("|") { p = p.dropLast() }
        if p.hasSuffix("^") || p.hasSuffix("/") { p = p.dropLast() }
        guard !p.isEmpty, p.utf8.allSatisfy({ b in
            (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z")) || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
                || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")) || b == UInt8(ascii: ".") || b == UInt8(ascii: "-")
        }) else { return nil }
        return p.lowercased()
    }

    struct Builder {
        var skipped: [SkipReason: Int] = [:]
        var converted = 0

        // Network
        var blockUnits: [[ContentRule]] = []
        var exceptions: [ContentRule] = []
        var importantRules: [ContentRule] = []
        var seenBlocks = Set<[ContentRule]>()
        var seenExceptions = Set<ContentRule>()

        // Cosmetic
        var genericOrder: [String] = []
        var genericSet = Set<String>()
        var genericRemoved = Set<String>()
        var genericExceptions: [String: Set<String>] = [:]
        var excludesOnly: [(selector: String, excludes: [String])] = []
        var specific: [(selector: String, includes: [String], excludes: [String])] = []
        var genericHideDomains = Set<String>()
        var elemHideDomains = Set<String>()

        mutating func skip(_ reason: SkipReason) { skipped[reason, default: 0] += 1 }

        // MARK: Network

        mutating func addNetwork(_ line: String) {
            var body = Substring(line)
            let isException = body.hasPrefix("@@")
            if isException { body = body.dropFirst(2) }

            var pattern = body
            var optionText: Substring = ""
            // `/regex$/` (no options) keeps its `$`; otherwise the last `$` starts the options.
            let isBareRegex = body.count > 2 && body.hasPrefix("/") && body.hasSuffix("/")
            if !isBareRegex, let dollar = body.lastIndex(of: "$") {
                pattern = body[..<dollar]
                optionText = body[body.index(after: dollar)...]
            }

            var thirdParty: Bool? = nil
            var domains = DomainSet()
            var important = false
            var matchCase = false
            var positive = Set<ABPType>()
            var negative = Set<ABPType>()
            var allTypes = false
            var sawUnsupportedType = false
            var generichide = false
            var elemhide = false

            if !optionText.isEmpty {
                for rawOption in optionText.split(separator: ",") {
                    var option = Substring(rawOption.lowercased())
                    let negated = option.hasPrefix("~")
                    if negated { option = option.dropFirst() }
                    var value: Substring = ""
                    if let eq = option.firstIndex(of: "=") {
                        value = option[option.index(after: eq)...]
                        option = option[..<eq]
                    }
                    switch option {
                    case "third-party", "3p": thirdParty = !negated
                    case "first-party", "1p": thirdParty = negated
                    case "domain", "from":
                        domains = parseDomains(value.split(separator: "|"))
                        // Keep original case for nothing: domains are lowercased by parseDomains.
                    case "important": important = true
                    case "match-case": matchCase = true
                    case "generichide", "ghide": generichide = true
                    case "elemhide", "ehide": elemhide = true
                    case "all": allTypes = true
                    case "redirect", "redirect-rule", "rewrite": skip(.redirect); return
                    case "removeparam", "queryprune": skip(.removeparam); return
                    case "csp", "permissions": skip(.csp); return
                    case "replace", "urltransform", "uritransform": skip(.replace); return
                    case "webrtc", "popunder":
                        if negated { continue }
                        sawUnsupportedType = true
                    default:
                        if option.allSatisfy({ $0 == "_" }) { continue }
                        if let type = ABPType.named(option) {
                            if negated { negative.insert(type) } else { positive.insert(type) }
                        } else {
                            skip(.unsupportedOption)
                            return
                        }
                    }
                }
            }

            if domains.droppedInclude && domains.includes.isEmpty {
                skip(domains.droppedReason ?? .entityDomain)
                return
            }

            // Page-level exceptions: $document / $elemhide / $generichide.
            if isException && (positive.contains(.document) || elemhide || generichide) {
                guard let host = plainHost(pattern) else {
                    positive.remove(.document)
                    if positive.isEmpty { skip(.unsupportedException); return }
                    // fall through for the remaining types
                    return addNetworkRule(pattern: pattern, isException: true, thirdParty: thirdParty, domains: domains,
                                          important: important, matchCase: matchCase, positive: positive, negative: negative,
                                          allTypes: allTypes, sawUnsupportedType: sawUnsupportedType)
                }
                if positive.contains(.document) {
                    elemHideDomains.insert(host)
                    let rule = ContentRule(action: .ignorePreviousRules, urlFilter: ".*", ifDomain: ["*" + host])
                    if seenExceptions.insert(rule).inserted { exceptions.append(rule) }
                    positive.remove(.document)
                }
                if elemhide { elemHideDomains.insert(host) }
                if generichide { genericHideDomains.insert(host) }
                converted += 1
                if positive.isEmpty { return }
                converted -= 1
            }

            addNetworkRule(pattern: pattern, isException: isException, thirdParty: thirdParty, domains: domains,
                           important: important, matchCase: matchCase, positive: positive, negative: negative,
                           allTypes: allTypes, sawUnsupportedType: sawUnsupportedType)
        }

        mutating func addNetworkRule(pattern: Substring, isException: Bool, thirdParty: Bool?, domains: DomainSet,
                                     important: Bool, matchCase: Bool, positive: Set<ABPType>, negative: Set<ABPType>,
                                     allTypes: Bool, sawUnsupportedType: Bool) {
            let urlFilter: String
            switch PatternTranslator.translate(String(pattern)) {
            case .filter(let f): urlFilter = f
            case .skip(let reason): skip(reason); return
            }
            let hostAnchored = pattern.hasPrefix("||")

            // Resource type groups: (resource-type, load-context).
            var groups: [([String]?, [String]?)] = []
            if allTypes {
                groups = [(nil, nil)]
            } else if positive.isEmpty && negative.isEmpty {
                if sawUnsupportedType { skip(.unsupportedResourceType); return }
                if isException || hostAnchored {
                    groups = [(nil, nil)]
                } else {
                    groups = [(defaultSubresourceTypes, nil), (["document"], ["child-frame"])]
                }
            } else {
                let types = positive.isEmpty ? ABPType.defaults.subtracting(negative) : positive.subtracting(negative)
                let nonDocument = ABPType.allCases.filter { types.contains($0) }.compactMap(\.appleType)
                if !nonDocument.isEmpty { groups.append((nonDocument, nil)) }
                let sub = types.contains(.subdocument), doc = types.contains(.document)
                if sub && doc { groups.append((["document"], nil)) }
                else if sub { groups.append((["document"], ["child-frame"])) }
                else if doc { groups.append((["document"], ["top-frame"])) }
                if groups.isEmpty { skip(.unsupportedResourceType); return }
            }

            var ifDomain: [String]? = domains.includes.isEmpty ? nil : domains.includes.map { "*" + $0 }
            var unlessDomain: [String]? = nil
            var pairedExcludes: [String] = []
            if domains.includes.isEmpty {
                if !domains.excludes.isEmpty { unlessDomain = domains.excludes.map { "*" + $0 } }
            } else {
                // Only excludes that are subdomains of an include matter.
                pairedExcludes = domains.excludes.filter { ex in domains.includes.contains { isSubdomain(ex, of: $0) } }
            }
            if ifDomain?.isEmpty == true { ifDomain = nil }

            if urlFilter == ".*" && ifDomain == nil && unlessDomain == nil && !isException {
                skip(.tooBroad)
                return
            }

            let loadTypes: [String]? = thirdParty.map { $0 ? ["third-party"] : ["first-party"] }
            var unit: [ContentRule] = []
            for (resourceTypes, loadContext) in groups {
                let rule = ContentRule(action: isException ? .ignorePreviousRules : .block, urlFilter: urlFilter,
                                       caseSensitive: matchCase, resourceTypes: resourceTypes, loadTypes: loadTypes,
                                       ifDomain: ifDomain, unlessDomain: unlessDomain, loadContext: loadContext)
                unit.append(rule)
                if !isException && !pairedExcludes.isEmpty {
                    var twin = rule
                    twin.action = .ignorePreviousRules
                    twin.ifDomain = pairedExcludes.map { "*" + $0 }
                    unit.append(twin)
                }
            }

            converted += 1
            if isException {
                for rule in unit where seenExceptions.insert(rule).inserted { exceptions.append(rule) }
            } else if important {
                importantRules.append(contentsOf: unit)
            } else if seenBlocks.insert(unit).inserted {
                blockUnits.append(unit)
            }
        }

        // MARK: Cosmetic

        mutating func addCosmetic(domains domainText: String, marker: CosmeticMarker, body: String) {
            switch marker {
            case .extended, .extendedException: skip(.proceduralCosmetic); return
            case .snippet, .snippetException, .script, .scriptException: skip(.scriptlet); return
            case .hide, .hideException: break
            }
            if body.hasPrefix("+js(") { skip(.scriptlet); return }
            if body.hasPrefix("^") { skip(.htmlFilter); return }
            let selector = body.trimmingCharacters(in: .whitespaces)
            if let reason = validateSelector(selector) { skip(reason); return }

            let domains = parseDomains(domainText.split(separator: ","))
            if domains.droppedInclude && domains.includes.isEmpty {
                skip(domains.droppedReason ?? .entityDomain)
                return
            }
            converted += 1

            if marker == .hideException {
                if domains.includes.isEmpty {
                    genericRemoved.insert(selector)
                } else {
                    genericExceptions[selector, default: []].formUnion(domains.includes)
                }
                return
            }
            if domains.includes.isEmpty {
                if domains.excludes.isEmpty {
                    if genericSet.insert(selector).inserted { genericOrder.append(selector) }
                } else {
                    excludesOnly.append((selector, domains.excludes))
                }
            } else {
                specific.append((selector, domains.includes, domains.excludes))
            }
        }

        // MARK: Output

        mutating func finish(maxRulesPerList cap: Int) -> ConversionResult {
            var index = CosmeticIndex()
            index.genericHideDomains = genericHideDomains
            index.elemHideDomains = elemHideDomains

            // Generic selectors: plain batch vs. with exceptions (unless-domain groups).
            var plainGeneric: [String] = []
            var unlessGroups: [String: (domains: [String], selectors: [String])] = [:]
            var unlessOrder: [String] = []
            func addUnless(_ selector: String, _ domains: Set<String>) {
                let sorted = domains.sorted()
                let key = sorted.joined(separator: ",")
                if unlessGroups[key] == nil { unlessGroups[key] = (sorted, []); unlessOrder.append(key) }
                unlessGroups[key]!.selectors.append(selector)
                index.genericExceptions[selector] = sorted
            }
            for selector in genericOrder where !genericRemoved.contains(selector) {
                if let exc = genericExceptions[selector], !exc.isEmpty {
                    addUnless(selector, exc)
                } else {
                    plainGeneric.append(selector)
                }
            }
            var seenExcludesOnly = Set<String>()
            for (selector, excludes) in excludesOnly
            where !genericRemoved.contains(selector) && !genericSet.contains(selector) && seenExcludesOnly.insert(selector).inserted {
                addUnless(selector, Set(excludes).union(genericExceptions[selector] ?? []))
            }
            index.genericSelectors = plainGeneric

            // Domain-specific selectors.
            var ifGroups: [String: (domains: [String], selectors: [String])] = [:]
            var ifOrder: [String] = []
            var seenSpecific = Set<String>()
            for var entry in specific {
                if let exc = genericExceptions[entry.selector] {
                    for d in exc {
                        if let i = entry.includes.firstIndex(of: d) {
                            entry.includes.remove(at: i)
                        } else if entry.includes.contains(where: { isSubdomain(d, of: $0) }) {
                            entry.excludes.append(d)
                        }
                    }
                }
                if entry.includes.isEmpty { continue }
                let excludes = entry.excludes.filter { ex in entry.includes.contains { isSubdomain(ex, of: $0) } }
                let covered = excludes.isEmpty
                for d in entry.includes {
                    let key = d + "\u{1}" + entry.selector
                    guard seenSpecific.insert(key).inserted else { continue }
                    index.byDomain[d, default: []].append(.init(selector: entry.selector, excludes: excludes,
                                                                 coveredByContentRules: covered))
                }
                if covered {
                    let sorted = Array(Set(entry.includes)).sorted()
                    let key = sorted.joined(separator: ",")
                    if ifGroups[key] == nil { ifGroups[key] = (sorted, []); ifOrder.append(key) }
                    ifGroups[key]!.selectors.append(entry.selector)
                }
            }

            func batches(_ selectors: [String]) -> [String] {
                var unique: [String] = []
                var seen = Set<String>()
                for s in selectors where seen.insert(s).inserted { unique.append(s) }
                return stride(from: 0, to: unique.count, by: selectorsPerRule).map {
                    unique[$0..<min($0 + selectorsPerRule, unique.count)].joined(separator: ", ")
                }
            }

            var genericRules: [ContentRule] = batches(plainGeneric).map {
                ContentRule(action: .cssDisplayNone, selector: $0, urlFilter: ".*")
            }
            for key in unlessOrder {
                let g = unlessGroups[key]!
                for sel in batches(g.selectors) {
                    genericRules.append(ContentRule(action: .cssDisplayNone, selector: sel, urlFilter: ".*",
                                                    unlessDomain: g.domains.map { "*" + $0 }))
                }
            }
            var specificRules: [ContentRule] = []
            for key in ifOrder {
                let g = ifGroups[key]!
                for sel in batches(g.selectors) {
                    specificRules.append(ContentRule(action: .cssDisplayNone, selector: sel, urlFilter: ".*",
                                                     ifDomain: g.domains.map { "*" + $0 }))
                }
            }
            let genericHideIgnores = genericHideDomains.sorted().map {
                ContentRule(action: .ignorePreviousRules, urlFilter: ".*", ifDomain: ["*" + $0])
            }
            let elemHideIgnores = elemHideDomains.sorted().map {
                ContentRule(action: .ignorePreviousRules, urlFilter: ".*", ifDomain: ["*" + $0])
            }

            // Network lists.
            let networkTail = exceptions + importantRules
            var networkLists = pack(units: blockUnits, suffix: networkTail, cap: cap)
            if networkLists.isEmpty && !importantRules.isEmpty { networkLists = [networkTail] }

            // Cosmetic lists.
            var cosmeticLists: [[ContentRule]] = []
            let cosmeticTotal = genericRules.count + specificRules.count + genericHideIgnores.count + elemHideIgnores.count
            if !genericRules.isEmpty || !specificRules.isEmpty {
                if cosmeticTotal <= cap {
                    cosmeticLists = [genericRules + genericHideIgnores + specificRules + elemHideIgnores]
                } else {
                    cosmeticLists = pack(units: genericRules.map { [$0] }, suffix: genericHideIgnores + elemHideIgnores, cap: cap)
                        + pack(units: specificRules.map { [$0] }, suffix: elemHideIgnores, cap: cap)
                }
            }

            let networkCount = networkLists.reduce(0) { $0 + $1.count }
            let cosmeticCount = cosmeticLists.reduce(0) { $0 + $1.count }
            return ConversionResult(
                lists: (networkLists + cosmeticLists).map(encodeRuleList),
                ruleCount: networkCount + cosmeticCount,
                networkRuleCount: networkCount,
                cosmeticRuleCount: cosmeticCount,
                convertedFilterCount: converted,
                skipped: skipped,
                cosmetic: index
            )
        }
    }

    /// Packs units (kept together) into lists of at most `cap` rules, each ending with `suffix`.
    static func pack(units: [[ContentRule]], suffix: [ContentRule], cap: Int) -> [[ContentRule]] {
        let room = max(1, cap - suffix.count)
        var lists: [[ContentRule]] = []
        var current: [ContentRule] = []
        for unit in units {
            if !current.isEmpty && current.count + unit.count > room {
                lists.append(current + suffix)
                current = []
            }
            current.append(contentsOf: unit)
        }
        if !current.isEmpty { lists.append(current + suffix) }
        return lists
    }
}
