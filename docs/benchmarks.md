# Benchmarks (2026-11-08, this Mac: Apple Silicon, macOS 27.2)

Method: `scripts/bench-compare.sh 25`. The same five sites (The Verge, Wikipedia, GitHub Trending, YouTube, Hacker News) are opened at launch and measured after 25 s. Memory is the summed `phys_footprint` of every process the browser uses (app, renderers/WebContent, GPU, network). Edge runs with a throwaway `--user-data-dir`. There are two rounds; round 2 is warm.

| | Aegis | Microsoft Edge (Chromium) |
|---|---|---|
| Launch to first window | 0.61–0.67 s | 1.04–1.27 s |
| Total memory, 5 sites | 666–752 MB | 1,301–1,335 MB |
| Processes | 9 | 21 |
| App process alone | 54–57 MB | n/a |

**Aegis launches about 40% faster and uses about 45% less memory with the same pages open.**

Caveats:
- Aegis blocks ads and trackers by default and Edge doesn't, so some of the memory gap is the blocker doing its job.
- Page rendering and JavaScript speed match Safari, because both use the system WebKit. Safari wasn't measured, so the user's own Safari session and history weren't touched.

Other measurements:
- Idle (no tabs): app process 40 MB.
- Hibernation: with 5 sites loaded, putting 4 background tabs to sleep cut WebKit memory from 751 MB to 300 MB.
- Palette ranking: 20k history entries + 100 tabs + 60 commands in 2.9 ms (release); fuzzy match over 20k candidates in 3–6 ms.
- Filter lists: EasyList + EasyPrivacy convert in 0.74 s and compile in 3.2 s on first launch; cached lookup takes 7 ms, and later launches skip conversion entirely.
