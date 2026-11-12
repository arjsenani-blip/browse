# Subfolders (nested folders in Pinned)

Status: **the model and store are done and tested, there is no UI yet.** The sidebar draws one level of folders, and nothing in the app creates a subfolder yet. Tests: `Tests/BrowserCoreTests/NestedFolderTests.swift`.

## Model (`BrowserCore/Models.swift`)

- `Folder.parentID: UUID?`: the folder that contains it. `nil` means top level. It's optional so sessions saved before nesting still decode, as top-level folders.
- `Folder.position`: the folder's slot among its siblings, counting tabs as well as folders:
  - top level: among the loose pinned tabs and the other top-level folders
  - inside a folder: among the parent's tabs and subfolders
- `Space.maxFolderDepth = 4`: a top-level folder has depth 0, so folders can go four levels deep.
- Space helpers:
  - `pinnedEntries`: top level only
  - `entries(in:)`: a folder's tabs and subfolders, interleaved by position
  - `subfolders(of:)`
  - `depth(of:)`
  - `ancestors(of:)` and `descendants(of:)`: both stay safe on a cyclic or broken chain
  - `subtreeHeight(of:)`
  - `allTabs(inFolder:)`: covers the whole subtree

## Store (`BrowserCore/BrowserStore.swift`)

| Call | Behaviour |
|---|---|
| `newSubfolder(in:name:)` | Adds the subfolder at the top of the parent and expands the parent. Returns `nil` if the parent doesn't exist or the depth limit is reached. |
| `moveFolder(_:toParent:at:)` | Moves a folder and everything under it. Closes the gap in the old scope and opens a slot in the new one. Refuses moves into itself or its own subtree, moves across spaces, and moves that would nest deeper than `maxFolderDepth` (it checks the parent's depth plus the moved tree's height). |
| `deleteFolder(_:closeTabs: false)` | Subfolders move up into the deleted folder's slot. Its tabs go to the parent folder, or become loose pinned tabs at the top level. Later siblings shift so the order stays the same. |
| `deleteFolder(_:closeTabs: true)` | Removes the whole subtree and closes every tab in it. |

Fixed while writing the tests (2026-11-12):
- Deleting a folder with no subfolders left a gap, so the next folder dropped one slot.
- `moveFolder` inside a folder couldn't put a subfolder after the parent's tabs.

## What the UI needs

1. **Mapping** (`BrowserWindowController`, around `page.pinnedEntries`): `FolderRow.children` is `[Row]` (tabs only) today.
   - Change it to `[PinnedItem]` built from `space.entries(in:)`, recursively.
   - Until then, tabs inside a subfolder don't appear in the sidebar. That's harmless for now, because nothing can create a subfolder.
2. **Rendering** (`ChromeUI/Sidebar.swift`): indent each level by about 12 pt, with the disclosure chevron per folder. Collapsing a folder hides its whole subtree.
3. **Creating a subfolder:**
   - folder context menu → "New Subfolder"
   - drag a folder onto the middle of another folder (the top and bottom edges reorder)
   - hide or disable both at depth 3
4. **Drag and drop:** use `moveFolder`, and show a "can't drop" state when it would return false (own subtree, too deep).
5. **"Move to Folder" menu** for a tab: show the tree indented, not a flat list.
6. **Delete confirmation:** when the folder has subfolders, say that they move up a level.

Before building the UI, mock up the indented tree and the drop targets with the stageshow skill (`design/stageshow/examples/`), following the design rule in CLAUDE.md.
