# overleaf.nvim

Neovim plugin for real-time collaborative LaTeX editing on [Overleaf](https://www.overleaf.com).

Edit your Overleaf projects directly in Neovim with full real-time collaboration support via Operational Transformation (OT). Use your favorite Neovim plugins — treesitter, LSP, snippets, copilot, and more — while collaborating with others on Overleaf.

---

## About this fork

This is a maintenance fork of [richwomanbtc/overleaf.nvim](https://github.com/richwomanbtc/overleaf.nvim)
by Kenji Kubo, which has had no commits since March 2026 and several open issues
with unmerged fixes. All credit for the plugin belongs upstream; this fork exists
only to carry fixes that upstream has not merged. It remains MIT licensed under
the original copyright.

### Changes relative to upstream

| Change | Why |
|---|---|
| Pin build-output downloads to the CLSI server | Overleaf serves `output.pdf` and `output.log` only from the CLSI node that produced them, selected by a `clsiserverid` query param. Without it both 404, so compiles produced a 0-byte PDF and no diagnostics — while still reporting success. Fixes [#24](https://github.com/richwomanbtc/overleaf.nvim/issues/24); equivalent to unmerged [#25](https://github.com/richwomanbtc/overleaf.nvim/pull/25). |
| Non-blocking PDF open | The auto-detect path used `vim.fn.system()`, freezing Neovim for as long as the PDF viewer stayed open. Now uses `vim.ui.open()`, which detaches, disables the pipes, and returns immediately. |
| `:Overleaf main` | Overleaf compiles whatever the project's server-side `rootDoc_id` points at, and the plugin had no way to change it — so the main document could only be set from the Overleaf web UI. Adds a picker and `<leader>om`. |
| Browser cookie extraction on Linux | Upstream only supported macOS. Every profile of every detected Chrome/Chromium install is searched — including Flatpak and Snap — and the most recently used Overleaf session wins, so no cookie needs to be configured by hand. Builds on unmerged [#15](https://github.com/richwomanbtc/overleaf.nvim/pull/15). |
| Sync race guards | Rejoin no longer wipes a populated buffer when the server returns empty, and disk writes are atomic. From unmerged [#22](https://github.com/richwomanbtc/overleaf.nvim/pull/22), plus a fix to re-arm the file watcher after the rename (`rename()` replaces the inode, which otherwise silently kills inbound sync). |
| Buffer changes reconciled on the next tick | The old pipeline reconstructed inserted text by reading the buffer from inside the `on_bytes` callback, where the visible state is inconsistent — a join reports pre-change content, typing reports post-change. Joins, line opens, whole-buffer rewrites and multibyte edits silently corrupted the mirror and forced a rejoin. Changes now record only which lines are dirty and are diffed once the buffer has settled. Fixes [#16](https://github.com/richwomanbtc/overleaf.nvim/issues/16). |
| Editable "binary" files | Overleaf decides doc-vs-file by extension at upload time, so an `.asm`, `.c` or other off-whitelist file is stored as an opaque fileRef even when its content is text, and the web editor refuses to open it. The plugin mirrored such files to disk once and then ignored them: edits there were silently lost and the copy went stale. Text fileRefs are now detected (UTF-8, no NUL bytes, Overleaf's own rule), kept current, opened from the tree, and re-uploaded on save, which Overleaf treats as a replace. See [Files Overleaf stores as binary](#files-overleaf-stores-as-binary). |
| `:Overleaf upload` works against overleaf.com | Overleaf's upload endpoint takes the file's name from a separate `name` form field and answered every upload with `422 invalid_filename`, so the command had never actually worked. The bridge now sends the field. |
| Reverting a disk edit is synced | Once an external edit had been synced, restoring the file to the bytes the plugin last wrote itself looked like the plugin's own write echoing back and was dropped, so an undo or revert by an external tool never reached Overleaf. The in-sync state is now updated when an external change is accepted. |
| Comments and suggestions survive external edits | A file rewritten on disk reached Overleaf as "delete the whole document, type it back" (a closed doc) or "delete everything between the first and last change" (an open one). Overleaf drops a comment or suggestion anchored to any text an op deletes, even when it is put straight back, so one changed word wiped every anchor in the file — the comment collapsed to an empty range, suggested insertions vanished and suggested deletions were displaced to the end. Changes are now diffed by word and only the words that differ are touched. See [Comments and suggestions](#comments-and-suggestions). |
| Editing / suggesting / viewing modes | The client could only edit outright. `:Overleaf mode` adds Overleaf's other two: **suggesting** sends every edit as a tracked change, and **viewing** is read-only and sends nothing — from the buffer or from the disk mirror. Modes the server would reject (a reviewer's plain edits, a read-only collaborator) are never offered, and a project that forces tracking on for you is respected. See [Modes](#modes). |
| Comment highlights follow the text | Highlight and "read comment at cursor" positions were recorded once at join and never updated, so after any edit above a comment the highlight drifted, the thread was no longer found under the cursor, and in text with accents the offsets (characters) were read as bytes. Positions are now read back from the extmarks that track the text. |
| Inverse search (SyncTeX) | Viewer clicks jump to project source. Zathura and Evince use D-Bus signals; Okular uses an editor callback to the running Neovim. See [SyncTeX inverse search](#synctex-inverse-search). |
| Forward search (SyncTeX) | `:Overleaf forward` moves zathura, Okular or Evince using the downloaded SyncTeX database. See [SyncTeX forward search](#synctex-forward-search). |
| Compiling does not steal focus | Every compile relaunched the PDF viewer, so the window manager pulled focus away from Neovim — which makes compiling on `:w` unusable. The output is written to the same path on every build, so a viewer that reloads on change is already current; `pdf_auto_open` now launches it for the first compile only by default, and downloads are staged through a sibling file and renamed so a watching viewer never reads a half-written PDF. |
| Relocatable keymap prefix | Every default key was hardcoded under `<leader>o`, and the documented `keys = false` escape hatch did not work (`opts.keys or true` is always truthy), so a collision with another `<leader>o` plugin could only be resolved by unmapping keys by hand. `keymap_prefix` moves the whole set, `keymaps = false` disables it, and the prefix is labelled in which-key when it is installed. |
| `env_file` accepts `~` and `$VAR` | `io.open` takes paths literally, so `~/.overleaf.env` was read as a directory named `~` and silently failed. Same intent as unmerged [#23](https://github.com/richwomanbtc/overleaf.nvim/pull/23). |

### Using this fork

```lua
{
  "EdgesFTW/overleaf.nvim",
  config = function()
    require("overleaf").setup({
      -- see Authentication below
    })
  end,
  build = "cd node && npm install",
}
```

### Setting the main document

`:Overleaf compile` builds the project's **main document**, which is a server-side
project setting — not whichever file you have open. Change it with:

```
:Overleaf main                  -- picker; the current main is marked *
:Overleaf main paper/main.tex   -- set directly (tab-completes)
<leader>om                      -- open the picker
```

Note that a `rootDoc_id` in the compile request body is ignored by Overleaf, so
this changes the project setting itself — the same thing the web UI's
*Menu → Main document* does, and it affects collaborators too.

---

## Features

- **Real-time collaboration** — edits sync instantly with other Overleaf users via OT
- **Full Neovim ecosystem** — treesitter, LSP, snippets, copilot, and all your plugins work out of the box
- **File tree** — browse and manage project files in a sidebar
- **Auto-authentication** — extracts session cookie from Chrome/Chromium automatically (macOS/Linux)
- **Auto-reconnect** — recovers from disconnects and document restores seamlessly
- **Compile & PDF preview** — compile LaTeX and open the PDF
- **Comments & reviews** — view, reply, resolve comment threads
- **Collaborator cursors** — see where other users are editing
- **Project-wide search** — grep across all documents
- **File management** — create, delete, rename, upload files
- **History** — view project version history
- **Diagnostics** — chktex linter + LaTeX compile errors via `vim.diagnostic`
- **LSP support** — auto-attaches texlab, ltex, harper_ls to overleaf buffers
- **Local file sync** — mirror documents to disk for external tools (Claude Code, etc.)

## Requirements

- Neovim >= 0.10
- Node.js >= 18
- An [Overleaf](https://www.overleaf.com) account
- Chrome / Chromium (for automatic cookie extraction) or a session cookie
- `sqlite3` CLI (required for automatic cookie extraction on Linux)

## Installation

### lazy.nvim

```lua
{
  'richwomanbtc/overleaf.nvim',
  config = function()
    require('overleaf').setup()
  end,
  build = 'cd node && npm install',
}
```

If Node.js is not on your default PATH (e.g., installed via Homebrew on macOS):

```lua
{
  'richwomanbtc/overleaf.nvim',
  config = function()
    require('overleaf').setup({
      node_path = '/opt/homebrew/bin/node',
    })
  end,
  build = 'cd node && npm install',
}
```

### Manual

```sh
git clone https://github.com/richwomanbtc/overleaf.nvim ~/.local/share/nvim/lazy/overleaf.nvim
cd ~/.local/share/nvim/lazy/overleaf.nvim/node && npm install
```

## Authentication

### Option 1: Chrome / Chromium (automatic on macOS/Linux)

Just log in to [overleaf.com](https://www.overleaf.com) in Chrome/Chromium. The plugin extracts the session cookie automatically. If you have multiple profiles, you'll be prompted to select one.

On Linux, `sqlite3` is required for cookie extraction (pre-installed on most Ubuntu/Debian systems):

```sh
sudo apt install sqlite3
```

To enable GNOME Keyring support (needed for newer Chrome v11 encrypted cookies), also install `libsecret-tools`. Without it the plugin falls back to Chrome's default password, which works for most users:

```sh
sudo apt install libsecret-tools
```

If cookie extraction fails, set `log_level = 'debug'` for detailed diagnostics.

### Option 2: Manual cookie

Create a `.env` file in your working directory:

```
OVERLEAF_COOKIE=overleaf_session2=s%3Ayour_cookie_value_here
```

Or pass it directly in setup:

```lua
require('overleaf').setup({
  cookie = 'overleaf_session2=s%3Ayour_cookie_value_here',
})
```

> **Warning:** If you use this method, make sure your Neovim config is not committed to a public dotfiles repository — the cookie would grant full access to your Overleaf account.

To get the cookie manually: open overleaf.com in your browser → DevTools (F12) → Application → Cookies → `www.overleaf.com` → find `overleaf_session2` → copy the cookie value (starts with `overleaf_session2=s%3A...`).

If you accidentally paste only the value (starting with `s%3A...`), the plugin auto-prepends `overleaf_session2=` and shows a warning.

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `:Overleaf` | Connect (or show status if connected) |
| `:Overleaf connect` | Connect to Overleaf |
| `:Overleaf disconnect` | Disconnect |
| `:Overleaf compile` | Compile LaTeX project |
| `:Overleaf tree` | Toggle file tree |
| `:Overleaf open` | Open a document |
| `:Overleaf projects` | Switch project |
| `:Overleaf status` | Show connection status |
| `:Overleaf preview` | Open a binary file (image, PDF) in an external viewer |
| `:Overleaf pdf` | Open the last compiled PDF in the viewer |
| `:Overleaf forward` | Move the viewer to the cursor's position in the PDF (SyncTeX) |
| `:Overleaf mode [name]` | Switch between `editing`, `suggesting` and `viewing`; with no argument, pick from a list |
| `:Overleaf new [name]` | Create new document |
| `:Overleaf mkdir [name]` | Create new folder |
| `:Overleaf delete` | Delete file/folder |
| `:Overleaf rename` | Rename file/folder |
| `:Overleaf upload [path]` | Upload local file |
| `:Overleaf search [pattern]` | Search across all documents |
| `:Overleaf comments` | List all comments |
| `:Overleaf comments refresh` | Refresh comments from server |
| `:Overleaf history` | View project history |
| `:Overleaf sync` | Sync all documents to/from disk |
| `:Overleaf sync import` | Import external changes from disk to Overleaf |
| `:Overleaf sync export` | Export all documents to disk |

### Default Keymaps

All of these hang off `keymap_prefix`, `<leader>o` by default. Setting
`keymap_prefix = '<leader>ol'` moves the whole set to `<leader>olc`,
`<leader>old` and so on, which is the way out if another plugin already owns
`<leader>o`. `keymaps = false` registers none of them.

| Key | Description |
|-----|-------------|
| `<leader>oc` | Connect |
| `<leader>od` | Disconnect |
| `<leader>ob` | Build (compile) |
| `<leader>ot` | Toggle file tree |
| `<leader>oo` | Open document picker |
| `<leader>op` | Preview file |
| `<leader>or` | Read comment at cursor |
| `<leader>oR` | Reply to comment |
| `<leader>ox` | Resolve/reopen comment |
| `<leader>of` | Find in project (search) |
| `<leader>om` | Set main document |
| `<leader>ov` | View the compiled PDF |
| `<leader>os` | Forward search: move the viewer to the cursor |
| `<leader>oM` | Switch mode (editing / suggesting / viewing) |

### Tree Keymaps

| Key | Description |
|-----|-------------|
| `Enter` | Open document |
| `a` | New document |
| `A` | New folder |
| `d` | Delete |
| `r` | Rename |
| `u` | Upload file |
| `R` | Refresh tree |
| `q` | Close tree |

## Configuration

```lua
require('overleaf').setup({
  -- Path to .env file containing OVERLEAF_COOKIE (default: '.env')
  env_file = '.env',

  -- Session cookie (overrides .env)
  cookie = nil,

  -- Path to Node.js binary (default: 'node')
  node_path = 'node',

  -- Log level: 'debug', 'info', 'warn', 'error' (default: 'info')
  log_level = 'info',

  -- File tree order: 'name' (default, folders first and natural name order)
  -- or 'overleaf' (project storage order). The main document is marked with *.
  tree_sort = 'name',

  -- When a finished compile hands the PDF to the viewer. Every compile rewrites
  -- the same path atomically, so a viewer that reloads on change is already
  -- current: 'once' (default) launches it for the first compile of a session,
  -- 'always' after every compile, false never (':Overleaf pdf' opens it).
  pdf_auto_open = 'once',

  -- Built-in viewer profile; zathura, okular and evince are supported.
  pdf_viewer = 'zathura',

  -- How this client changes the project, as in Overleaf's editor:
  --   'auto' (default) - editing where the project allows it, else the nearest mode
  --   'editing'        - edits are applied as typed
  --   'suggesting'     - edits are sent as tracked changes (suggestions)
  --   'viewing'        - read-only; nothing is sent
  mode = 'auto',

  -- Enable inverse search. The SyncTeX database is still downloaded when false.
  inverse_search = true,

  -- Local file sync directory for external tools like Claude Code (default: nil = disabled)
  -- When set, all documents are mirrored to disk and external changes are synced back.
  sync_dir = '~/.overleaf',
  -- New files made in the mirror stay local by default. Set true to import
  -- Overleaf text documents; list binary extensions to allow fileRef uploads.
  sync_new_files = false, -- or true, or { binary = { 'png', 'pdf' } }
  -- Files Overleaf stores as binary but whose content is text (.asm, .c, ...):
  -- 'auto' (default) edits them by re-upload, a list like { 'asm', 'c' }
  -- restricts that to those extensions, false leaves them download-only.
  editable_files = 'auto',

  -- Prefix every default keymap hangs off. Move it when another plugin already
  -- claims '<leader>o' -- '<leader>ol' puts the whole set under a free key.
  keymap_prefix = '<leader>o',

  -- Set to false to disable the default keymaps entirely
  keymaps = true,
})
```

## Workflow

1. `:Overleaf` — authenticate and select a project
2. File tree appears — press `Enter` to open a document
3. Edit normally — changes sync to Overleaf in real-time
4. `:w` — triggers compile and opens PDF
5. `:Overleaf tree` — switch between documents

## External Tool Integration (Claude Code, etc.)

By default, Overleaf documents exist only as virtual buffers — they have no files on disk. This means external tools like Claude Code cannot read or edit them.

Set `sync_dir` to enable local file mirroring:

```lua
require('overleaf').setup({
  sync_dir = '~/.overleaf',  -- or any directory
})
```

When connected to a project, all text documents are synced to `~/.overleaf/<project-name>/`. External tools can read and edit these files — changes are automatically detected and synced back to Overleaf.

New files made on disk stay local by default. Set `sync_new_files = true` to
create Overleaf documents from new files with Overleaf's default text-document
extensions (including `tex`, `bib`, `sty`, `cls`, `txt`, and `md`). Use
`sync_new_files = { binary = { 'png', 'pdf' } }` to allow those fileRef uploads
as well. A new subfolder is created in the project before its file. Each
mirrored folder has its own watcher, and a file is imported after its size is
unchanged for 500 ms. Dotfiles, editor temp files, conflict copies, and LaTeX
build output are ignored. PDFs are ignored unless `pdf` is explicitly listed.
In viewing mode, imports are held. In suggesting mode, new text documents are
created empty and their content is sent as a tracked insertion; binary uploads
are held. If the server refuses creation, the file remains on disk and is held.
Disk deletions and renames are never sent to Overleaf automatically.

### How it works

- **On connect**: all documents are fetched and written to disk
- **Neovim edits**: debounced writes keep disk files up to date
- **Remote edits**: open documents and their disk files update live; closed documents' disk files refresh on connect, sync, or open
- **External edits**: file watchers detect changes and sync them to Overleaf via OT
  - For open documents: buffer is updated, triggering the normal OT pipeline
  - For closed documents: changes are sent directly via the bridge

### Commands

- `:Overleaf sync` — re-sync all documents (fetch from Overleaf and write to disk)
- `:Overleaf sync import` — import all external disk changes to Overleaf
- `:Overleaf sync export` — export all documents to disk
- `:Overleaf sync status` — list disk-only files, project files missing on disk,
  and held changes, even when automatic new-file import is off

`:Overleaf sync import` also checks disk-only files explicitly, using the same
extension and mode rules even when `sync_new_files = false`.

### Files Overleaf stores as binary

Overleaf only stores an upload as an editable document when its extension is
on its text whitelist (`.tex`, `.bib`, `.sty`, `.cls`, `.txt`, `.md`, and a
few more). Anything else, an `.asm` or `.c` file for instance, becomes a
"fileRef": an opaque blob with no real-time document behind it, which the web
editor cannot open either. There is no OT stream to send edits into, so the
only way to change one is to upload a replacement, which Overleaf accepts
under the same name and folder and gives a new id.

The plugin handles these as follows:

- On connect, a fileRef with an unknown extension is downloaded and checked
  the way Overleaf checks uploads: valid UTF-8 with no NUL bytes. Known
  binary extensions (images, PDFs, archives, fonts) are skipped and fetched
  once as before.
- Text fileRefs are mirrored into `sync_dir`, re-fetched on every connect and
  `:Overleaf sync` so the copy follows the server, and watched. A change on
  disk, from Neovim or from an external tool, is re-uploaded whole.
- `Enter` on one in the tree, or `:Overleaf open path/to/file.asm`, opens the
  mirrored file as a plain buffer. `:w` uploads it and then compiles, as it
  does for documents. Without a `sync_dir` the download is opened from a temp
  directory instead.
- `:Overleaf sync import` and `sync export` include them.
- A replacement made elsewhere (web upload, collaborator) is picked up from
  the `reciveNewFile` event and re-downloaded.

Caveats, since none of the real-time machinery applies:

- Saves are last-writer-wins. There is no merge and no live cursors, and two
  people editing the same fileRef will overwrite each other.
- History records each save as a whole-file upload, not a diff.
- Edits made to the mirror while not connected are discarded on the next
  connect, when the server copy is written over them (a warning is logged).

If you want real collaboration on such a file, rename it on Overleaf to a
whitelisted extension (`main.asm.txt`); it becomes a document and
`\lstinputlisting` and friends still read it.

Set `editable_files = false` to restore the old download-only behaviour, or
give a list of extensions to limit which fileRefs are treated this way.

### Usage with Claude Code

```bash
# Start Claude Code in the sync directory
cd ~/.overleaf/My\ Project
claude
```

Claude Code can now read all your LaTeX files and make edits that sync back to Overleaf in real-time.

## Modes

The same three modes as Overleaf's editor. Switch with `:Overleaf mode <name>`,
`<leader>oM`, or `mode = '...'` in `setup()`.

| Mode | What happens to an edit |
|---|---|
| `editing` | Applied as typed. The default. |
| `suggesting` | Sent as a **tracked change**: a suggestion the owner can accept or reject in Overleaf, anchored where you made it. |
| `viewing` | Nothing is sent. Buffers are read-only and changes to the disk mirror are held back, not pushed. |

- **It covers external tools too.** With `sync_dir` set, an edit made to the mirror
  by another program follows the current mode. `suggesting` plus Claude Code, a
  formatter or a script means their changes arrive as suggestions to review rather
  than as edits already applied.
- **Comments work in every mode**, as they do on the web: you can read, reply to
  and resolve them while viewing.
- **Only what the server allows is offered.** A `review` collaborator's plain edits
  are rejected by Overleaf, so they start in `suggesting` and cannot enter
  `editing`; a `readOnly` one is limited to `viewing`. If the project has tracking
  switched on for you, edits have to be suggestions (an owner is not bound by
  tracking they turned on for others).
- **Switching sends what you typed first**, so an edit goes out under the mode it
  was typed in.
- **Held changes.** Disk edits made while viewing are kept, not dropped. Leaving
  viewing tells you how many are waiting; `:Overleaf sync import` sends them.
- **A file replaced whole cannot be a suggestion.** Text Overleaf stores as a binary
  file (see [below](#files-overleaf-stores-as-binary)) is saved by re-uploading it,
  which is only done while `editing`.
- Structural changes (new, rename, delete, upload, main document) are refused while
  viewing.

`require('overleaf').statusline()` appends the mode when it is not the default:
`OL: Thesis / main.tex [suggesting]`.

Not implemented: suggestions are sent but not drawn. A suggested deletion is not in
the buffer at all (Overleaf stores the text on the side) and a suggested insertion
looks like ordinary text, so review and accept or reject in Overleaf. The mode is
this client's own — it does not move the web editor's Reviewing switch — and a
change to the project's tracking settings made while you are connected is noticed
on the next connect.

## Comments and suggestions

Overleaf anchors comments and suggestions to ranges of text. Any op that *deletes*
text an anchor covers removes it, even if the same text is typed straight back. So
an edit is sent as the words that changed and nothing more:

- an external rewrite of the mirror — open document or not — touches only the
  differing words, so a comment on the paragraph in between is undisturbed;
- a reflow that only moves whitespace touches no word at all;
- while `suggesting`, a replaced word is replaced whole (`lazy` struck out,
  `sleepy` added) rather than as `laz` → `sleep`; in `editing` the smallest edit is
  sent, which keeps an anchor on the surviving part of a word.

What still removes an anchor is what removes it on the web: deleting or replacing
all of the commented text.

Highlights and "read comment at cursor" follow the text as it is edited.

## SyncTeX forward search

`:Overleaf forward` (`<leader>os`) moves the PDF to the source at the cursor.
It uses the `output.synctex.gz` downloaded beside the PDF after every compile.
The search refers to the last compile, so editing without compiling can shift
the position. Compiling on `:w` keeps the source and PDF together. A comment,
preamble line or blank line may produce no output of its own; in that case the
viewer may simply not move. Search works from files opened out of the mirror
as well as live documents. The viewer resolves the source location itself;
there is no Overleaf HTTP lookup or box highlight.

Set `pdf_viewer` to `zathura`, `okular` or `evince` for a built-in profile. The
command may be an absolute executable path. With `pdf_viewer = nil`, the PDF
opens through the system default. Forward search then uses zathura only if one
is already showing that PDF; otherwise it asks you to set `pdf_viewer` for the
viewer you use. An unrecognised command opens the PDF and keeps zathura's
D-Bus inverse listener for compatibility, but needs a profile table for
forward search:

```lua
pdf_viewer = {
  name = 'sioyek',
  open = { 'sioyek', '@pdf' },
  forward = { 'sioyek', '--forward-search-file', '@file',
    '--forward-search-line', '@line', '@pdf' },
  inverse = { '--inverse-search', '@callback %f %l %c' },
}
```

This sioyek-style example is **untested**; adapt its flags to the installed
version. Profile commands are argv lists. `@pdf` is the absolute PDF path,
`@file` is the absolute source path recorded in the local SyncTeX database,
`@line` and `@column` are 1-based, and `@callback` is the Neovim callback
command. The optional `inverse` argv is inserted after the executable of the
`open` command when inverse search is enabled; it is never added to `forward`,
since a viewer that keeps a single instance (Okular's `--unique`) may refuse
an editor command from a second invocation. Unknown placeholders and viewer
syntax such as `%f` stay untouched. Put inverse flags in `inverse`, rather
than `open`, so they disappear cleanly when `inverse_search = false`. A profile
can set `forward = 'evince'` or
`listen = 'zathura'` / `'evince'` for those D-Bus drivers. For a viewer with
one running instance, `unique_bus` can name its well-known D-Bus owner; an
owned name makes `open` omit the inverse arguments that instance would refuse.

## SyncTeX inverse search

A viewer click jumps to the project document and line, opening it if needed.
The modifier belongs to the viewer: zathura uses ctrl+click by default (set
by `synctex-edit-modifier`), Okular uses shift+click in browse mode, and Evince
uses ctrl+click. Like forward search, the result reflects the last compile.

Zathura reports an `Edit` signal over D-Bus. The plugin
listens to this signal even for a zathura started by hand; it does not set
zathura's `-x` editor command because one click would trigger both paths.
Evince uses its D-Bus `SyncView` method and `SyncSource` signal. These two
viewers need `gdbus`; zathura's instance discovery also needs `busctl`.
GNOME Papers does not expose Evince's SyncTeX interface and is unsupported.

Okular uses an editor command. The command runs
`scripts/overleaf-inverse.lua` in a clean Neovim, which reads a hashed state
file in the user's private runtime directory and sends the result by RPC to
the running session. The file contains the Neovim server address, is written
with mode 0600, and is refreshed when the PDF is downloaded or opened. It is
removed on disconnect or exit when it still names this session. A viewer left
open can therefore reach a later Neovim session after that session compiles
the project. The callback uses the launching Neovim's `v:progpath`; if that
executable is a temporary AppImage path that vanishes when Neovim exits,
clicks from the older viewer stop working until it is reopened.
Okular only handles inverse search when the source path in SyncTeX exists on
disk, so set `sync_dir` to enable the local mirror for Okular.

Okular takes the editor command only when it starts. A second `okular --unique`
that tries to set one is refused. When `org.kde.okular` already owns its bus
name, `:Overleaf pdf` launches without that argument; forward search never
passes it either. An Okular started by hand or by forward search without the
callback will not report clicks. Close that instance and use `:Overleaf pdf`.
A source filename containing `#` breaks Okular's `pdf#src:` forward argument,
because Okular splits the argument at `#`.

When `sync_dir` is active, the plugin rewrites project `Input:` paths in the
downloaded SyncTeX database from `/compile/...` to the absolute mirror path.
TeX Live paths stay intact. This gives forward search the exact path expected
by each viewer and lets Okular open project source. Without `sync_dir`, the
build paths stay `/compile/...`; inverse clicks still map project files back
to their buffers. `inverse_search = false` disables listeners and callback
arguments but keeps the database download for forward search.

## Testing status and known gaps

Written down so nothing here is trusted further than it was tested. This is a
maintenance fork, not a released product, and several of the features above have
only been exercised by one person against one project.

**Checked against real Overleaf** (a scratch project owned by the tester, no other
collaborators, throwaway documents deleted afterwards):

- an external rewrite of an open and of a closed document keeps a comment and both
  a suggested insertion and a suggested deletion, at the right shifted positions,
  where the previous code lost them;
- `suggesting` produces tracked insertions and deletions, `editing` produces plain
  edits, `viewing` sends nothing, and a change held while viewing arrives as a plain
  edit afterwards;
- the older Overleaf SyncTeX lookup and zathura jump, before the viewer profiles
  replaced them.

**Checked live against real viewers, but on a local compile** (zathura, Okular
and Evince in a private X display, driven through the plugin by a headless
Neovim with a fake session; the PDF and SyncTeX database came from `pdflatex`
with their paths rewritten to Overleaf's `/compile/./` layout, since the
sandbox's login had expired):

- forward search moves each viewer to the right page, for files in the root
  and in a subfolder, with the database rewritten to the mirror and, for
  zathura, without it;
- a click lands on the right file and line: zathura's `Edit` and Evince's
  `SyncSource` through the D-Bus listener, Okular's through the editor
  command, the state file and the RPC callback;
- PDF names and mirror paths with spaces, brackets and an apostrophe. This
  found two bugs the unit tests had not: gdbus double-quotes a string that
  holds an apostrophe, which the signal parsers did not read, and Evince
  files a document under GLib's upper-case percent-escapes, which
  `vim.uri_from_fname` does not produce;
- with `pdf_viewer` unset and no zathura showing the PDF, forward search
  warns instead of starting a zathura.

**Checked only by unit tests and a mock server** (so only as reliable as the mock):

- the diff itself, including a randomized property test — it is compared against the
  text it should produce, and falls back to one coarse hunk if it ever does not;
- the mode policy, the read-only guarantees, the disk-mirror guards, and the `meta`
  the bridge attaches to a tracked update.

**Not checked at all:**

- **Any access level other than owner.** That a `review` collaborator's plain edits
  are rejected, and that a `readOnly` one cannot send, comes from reading Overleaf's
  source, not from trying it. The mode policy is built on that reading.
- **Forced tracking.** How the server reports "track changes is on for you"
  (`trackChangesState`, a boolean or a per-user map) was read from source and the
  test project has it empty, so the rule that binds a collaborator to `suggesting`
  has never been seen firing on a real project. A change to it made while you are
  connected is not noticed.
- **More than one person editing.** Nothing was tested with another collaborator
  editing at the same moment. A bulk change is sent as several hunks in descending
  order so that concurrent edits transform correctly, which holds by construction
  and in unit tests, not against a live second client.
- **Characters outside the Basic Multilingual Plane** (emoji and the like). Overleaf
  counts positions in UTF-16 units, the plugin in characters, and the content hash
  the bridge sends is computed from the JavaScript string. Accented text was
  tested; emoji was not.
- **Anything but the smallest case for suggestions.** Whole-word replacement was
  checked on one word. Interleaved suggestions from several people, undo history
  across a mode switch, and very large rewrites are untested.
- **The viewer profiles against a real Overleaf build.** See above: the live
  viewer checks used a local compile, so the bridge's download-and-rewrite of a
  real `output.synctex.gz` is covered by its unit test, not end to end. The
  sioyek example profile has not been run at all.
- **Lint.** `luacheck` was not run for this round of changes.

Treat the mode and suggestion behaviour as a first pass. If a suggestion looks
wrong in Overleaf, or a comment moves unexpectedly, that is a bug worth reporting
with the before and after text.

## How It Works

The plugin spawns a Node.js bridge process that connects to Overleaf's real-time collaboration server via Socket.IO. Edits in Neovim are converted to OT operations and sent to the server. Remote edits from other collaborators are transformed and applied to your buffer in real-time.

## Disclaimer

This is an **unofficial** plugin and is not affiliated with, endorsed by, or supported by [Overleaf](https://www.overleaf.com). It relies on Overleaf's internal real-time collaboration protocol, which is undocumented and may change at any time without notice. Such changes could cause the plugin to stop working, or in the worst case, lead to document corruption or data loss.

Overleaf maintains version history for all projects, so you can restore previous versions from the Overleaf web interface if anything goes wrong.

**Use this plugin at your own risk.** Always keep important work backed up.

## Acknowledgments

This project was developed with reference to the following projects for understanding Overleaf's real-time collaboration protocol:

- [AirLatex.vim](https://github.com/dmadisetti/AirLatex.vim) (MIT) — Neovim plugin for Overleaf by David Hartmann. Referenced for Chrome cookie extraction approach and Socket.IO connection patterns.
- [Overleaf-Workshop](https://github.com/iamhyc/Overleaf-Workshop) (AGPL-3.0) — VS Code extension for Overleaf. Referenced for protocol details including the v2 connection scheme, OT update hashing, and joinDoc parameters.

The code in this repository is an independent implementation in Lua/Node.js. No source code was directly copied from either project.

## License

MIT
