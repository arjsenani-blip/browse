# Research: omnibox, palette, reader, hibernation, split (2026-11-07)

## Frecency (Firefox model)
- Visit buckets: very high / high (typed, bookmarked) / medium (link) / low (redirect, reload). An "interesting" visit (long view time or many keypresses) moves up one bucket.
- Per-visit score w·e^(−λΔt), λ = ln2/30 days. Total = (sum of the last N sampled ÷ N) × visit_count.
- Store `t_ref + ln(score)/λ` (the date the score decays to 1), so the stored value is static and sortable; recompute at idle. Starting weights 100/70/50/20, N=10.
- Adaptive input history: input→url pairs; on pick `use = use·0.9 + 1`; daily ×0.975; drop below 0.1. Rank boost × (1 + exact match).
- Candidate gating (Chromium HQP): typed, ≥4 visits, or visited in the last 72h.

## Fuzzy: port fzf FuzzyMatchV2
- Constants: match 16, gap start −3, gap extension −1, boundary 8, whitespace 10, delimiter 9, camelCase 7, consecutive 4, first-character ×2. Run over UTF-8 `[UInt8]` with a reused Int16 slab; greedy V1 fallback for big inputs.
- Final score: `fuzzy × (1 + log1p(frecency)) + adaptiveBoost + sourceBoost` (open tab > bookmark > history > command); a host-prefix match beats a title match.
- Inline autocomplete: top result only; typed text is a prefix of the host (ignoring www.) or an adaptive key; typed_count ≥ 1; never after Backspace or with the caret not at the end.
- Latency: under 16 ms keystroke-to-paint. ~4 ms sync in-memory index (top 20k URLs + tabs + bookmarks + commands), ~8 ms async FTS5 (cancelled on the next keystroke). Remote suggestions are opt-in, debounced 50–100 ms, never sent for URL-like or private input.

## Schema
```sql
CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT UNIQUE, host TEXT, title TEXT,
  visit_count INT, typed_count INT, last_visit INT, frecency REAL);
CREATE TABLE visits(id INTEGER PRIMARY KEY, url_id INT, ts INT, kind INT, view_ms INT, keypresses INT);
CREATE TABLE input_history(input TEXT, url_id INT, use_count REAL, PRIMARY KEY(input,url_id));
CREATE VIRTUAL TABLE urls_fts USING fts5(title, url, host, content='urls', content_rowid='id',
  tokenize='trigram remove_diacritics 1');
CREATE INDEX urls_frecency ON urls(frecency DESC);
```
Sync via triggers; WAL mode; queries under 3 characters use the in-memory prefix index.

## Palette UX
Verb-first fuzzy commands with aliases. Tab on a result scopes into a mode (Tabs ▸, History ▸, @site); `>` forces commands. Sections: Switch to Tab, Actions, History/Bookmarks (max 3 each until the user arrows in). Shortcut shown on each row. Cmd+Enter opens a new tab, Shift+Enter opens a split. Esc pops the scope first. Never blocks typing.

## Reader mode
Readability.js: `isProbablyReaderable` decides when to show the button; `parse()` runs on a clone. Readability does not sanitize: add DOMPurify. Inject both in a named WKContentWorld. Render in a separate non-persistent WKWebView with JavaScript off and CSP `default-src 'none'; img-src https: data:; style-src 'unsafe-inline'`. Typography: max-width ~34em, line-height 1.55, 19–21px; sepia/dark themes; Cmd± for size.

## Hibernation
- Defaults: discard after 30 min; 5 min under a memory-pressure warning; immediately (least recently used first) when critical. `DispatchSource.makeMemoryPressureSource`.
- Exempt: media/camera/mic/screen-share active, unsubmitted form input, pinned (unless critical), downloads, visible split panes, allowlist.
- Restore: save `interactionState` + a snapshot, tear down the web view, restore into a fresh one (WebKit bug 232486: navigations after restore are flagged as app-initiated).
- UI: favicon at 50% opacity; hover shows "Sleeping – saved X MB"; snapshot shown instantly on activate.

## Split / tab search
2–4 panes; accent outline on the focused pane; Cmd+Opt+←/→ moves focus. Tab search groups this window / other windows / recently closed; Ctrl+Backspace closes the highlighted tab.

## Shortcuts
Cmd+K palette · Cmd+L address · Cmd+T new tab (opens the omnibox) · Cmd+Shift+A tab search · Cmd+Shift+T reopen · Ctrl+Tab most recent · Cmd+1–9 · Cmd+Shift+R reader · Cmd+Opt+N split · Cmd+Opt+W close pane · Cmd+Opt+H hibernate · Cmd+Shift+P pin · Cmd+/ cheat sheet · Cmd+S toggle sidebar · Cmd+Shift+C copy URL.
