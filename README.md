# Browse

A minimal, fast macOS browser with Arc-style spaces and a vertical sidebar, built on
[Helium](https://github.com/imputnet/helium-macos) (ungoogled Chromium 156).

> Unofficial personal project. Unsigned build — macOS will ask you to confirm the first
> time you open it (right-click Browse.app → Open).

## Features

- **Spaces** — each space is its own profile with separate cookies, logins and history
  (sign into a different Google account in each). Two-finger swipe on the sidebar to
  switch; space icons sit at the bottom of the sidebar.
- **New spaces the Arc way** — keep swiping past your last space and a ring "+" fills in;
  let go and the sidebar turns into a *Create a Space* panel (name, icon, neon color).
- **Folders** — keep tabs together in named folders; they're restored when you reopen
  the browser (Browse always continues where you left off).
- **Minimal sidebar** — neutral grey chrome, real favicons, one-line 28px tab rows, a
  quiet "Filter N tabs" field, automatic "Site · N" groups for 3+ tabs from one site,
  and an "Earlier" section for tabs you haven't touched in 12 hours.
- **Cmd+T command bar** — a floating search card over a soft gradient (search, history,
  switch to open tabs). No new tab page.
- **Neon loading bar** that follows real page progress.
- **Shift+Cmd+S** switches between the sidebar and a top tab bar.
- Opens straight into your Personal space — no profile chooser.
- No AI chat, no extra background services; Memory Saver on.

## Download

Grab `Browse.dmg` from [Releases](../../releases). macOS only (Intel build).

## Building from source

Browse is a set of patches on top of Helium's macOS build:

- `patches/browse/` — the Browse changes, applied last (see the end of `patches/series`).
- `browse-tools/name_sub/` — copy of Helium's name substitution that renames the
  product strings to "Browse" (run it in place of Helium's
  `utils/name_substitution.py`).

Follow Helium's macOS build instructions (`docs/`, `build.sh` / `dev.sh`) — the Browse
patches are picked up automatically from `patches/series`.

## License

GPL-3.0, same as Helium. Chromium and the bundled projects keep their own licenses.
Browse is not affiliated with Helium, Arc, Dia, or Google.
