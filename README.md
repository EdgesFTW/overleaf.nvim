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

  -- When a finished compile hands the PDF to the viewer. Every compile rewrites
  -- the same path atomically, so a viewer that reloads on change is already
  -- current: 'once' (default) launches it for the first compile of a session,
  -- 'always' after every compile, false never (':Overleaf pdf' opens it).
  pdf_auto_open = 'once',

  -- Local file sync directory for external tools like Claude Code (default: nil = disabled)
  -- When set, all documents are mirrored to disk and external changes are synced back.
  sync_dir = '~/.overleaf',
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

### How it works

- **On connect**: all documents are fetched and written to disk
- **Neovim edits**: debounced writes keep disk files up to date
- **Remote edits**: disk files are updated when collaborators make changes
- **External edits**: file watchers detect changes and sync them to Overleaf via OT
  - For open documents: buffer is updated, triggering the normal OT pipeline
  - For closed documents: changes are sent directly via the bridge

### Commands

- `:Overleaf sync` — re-sync all documents (fetch from Overleaf and write to disk)
- `:Overleaf sync import` — import all external disk changes to Overleaf
- `:Overleaf sync export` — export all documents to disk

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
