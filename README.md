# org-roam-ui.nvim

Neovim backend and packaged web UI for viewing an `org-roam.nvim` graph in the
browser.

This project ports the useful backend role of Emacs `org-roam-ui.el` to Lua. It
reads graph data from `chipsenkbeil/org-roam.nvim`, serves a patched static
`org-roam-ui` frontend, and speaks the same core HTTP/WebSocket protocol that
the browser app expects.

## Status

This is an early working prototype.

Implemented:

- Read nodes, links, and tags from the live `org-roam.nvim` database.
- Serialize graph data in the shape expected by `org-roam-ui`.
- Serve node text for sidebar previews.
- Serve local images referenced by notes.
- Serve a vendored static `org-roam-ui` frontend from `web/org-roam-ui`.
- Run HTTP on `127.0.0.1:35911`.
- Run WebSocket on `127.0.0.1:35913`.
- Send initial `variables`, `graphdata`, and `theme` WebSocket messages.
- Handle browser commands: `open`, `getText`, `refresh`.
- Optional hooks exist for future `create` and `delete` support.
- Refresh graph data on org file save.
- Push `follow`, `zoom`, `local`, and `theme` commands to the browser.
- Compute heading node `olp` (outline-level path) by walking the org file.
- Serialize `refs`, `aliases`, and forwarded properties (`NOTER_PAGE`, `ROAM_REFS`, `ROAM_ALIASES`).
- Export the live Neovim colorscheme as theme data via `auto_sync_theme`.
- Auto-follow cursor node on buffer switch via `follow_on_switch`.
- Toggle auto-follow at runtime with `OrgRoamUiToggleFollow`.
- Add/remove/replace nodes in the local graph via WebSocket commands.

Known incomplete areas:

- Full parity with Emacs `org-roam-ui` is not finished.
- Browser create/delete note flows are not implemented by default.
- Citation/ref support is basic and does not match Emacs org-roam + org-roam-bibtex.

## Requirements

- Neovim with LuaJIT.
- `nvim-orgmode/orgmode`.
- `chipsenkbeil/org-roam.nvim`.
- A populated `org-roam.nvim` database.
- `curl` for the test suite.

The test setup derives the repo root from `tests/minimal_init.lua`, so the repo
can live anywhere. If Plenary is not installed under Neovim's standard Lazy path,
set `LAZY_PATH` to the directory containing `plenary.nvim`.

## Installation

With Lazy.nvim or LazyVim:

```lua
return {
  {
    dir = "/path/to/org-roam-ui.nvim",
    name = "org-roam-ui-nvim",
    dependencies = { "chipsenkbeil/org-roam.nvim" },
    config = function()
      require("org-roam-ui-nvim").setup({
        port = 35911,
        websocket_port = 35913,
      })
    end,
  },
}
```

For local development in this workspace, the provided example is:

```text
lazyvim-plugin-spec.lua
```

## Usage

Start the backend and frontend server:

```vim
:OrgRoamUiStart
```

Open the UI:

```text
http://127.0.0.1:35911/
```

Stop it:

```vim
:OrgRoamUiStop
```

Inspect raw graph data:

```text
http://127.0.0.1:35911/graphdata
```

Other commands:

```vim
:OrgRoamUiRefresh
:OrgRoamUiFollow
:OrgRoamUiSyncTheme
:OrgRoamUiGraphData
:OrgRoamUiToggleFollow
:OrgRoamUiAddToLocalGraph
:OrgRoamUiRemoveFromLocalGraph
```

## Configuration

Defaults:

```lua
require("org-roam-ui-nvim").setup({
  host = "127.0.0.1",
  port = 35911,
  websocket_port = 35913,
  static_dir = nil,
  open_on_start = false,
  refresh_on_save = true,
  follow_on_switch = false,
  auto_sync_theme = false,
  org_roam = nil,
})
```

Options:

- `host`: Bind address for HTTP and WebSocket.
- `port`: HTTP/static frontend port.
- `websocket_port`: WebSocket port.
- `static_dir`: Override static frontend directory. Defaults to
  `web/org-roam-ui`.
- `open_on_start`: Open the browser with `vim.ui.open()`.
- `refresh_on_save`: Re-index saved org files and broadcast graph updates.
- `follow_on_switch`: Automatically follow the cursor node when switching org buffers.
- `auto_sync_theme`: Extract and broadcast the live Neovim colorscheme as theme data on connect.
- `org_roam`: Test/development injection point for a mocked org-roam instance.
- `roam_dir`: Override roam directory for frontend variables.
- `daily_dir`: Override daily notes directory for frontend variables.
- `attach_dir`: Override org attach directory for frontend variables.
- `use_inheritance`: Passed through to frontend org attachment rendering.
- `katex_macros`: Passed through to frontend org/KaTeX renderer.
- `theme`: Static theme data broadcast by `:OrgRoamUiSyncTheme` (overridden by `auto_sync_theme`).

## Rebuilding the Frontend

The vendored `web/org-roam-ui` is built from source using:

```sh
bash scripts/build-frontend.sh
```

This clones upstream `org-roam-ui` at the pinned commit, applies
`scripts/neovim-ports.patch` (which introduces `lib/backend.ts` to read
Neovim ports from `NEXT_PUBLIC_*` env vars), builds a static export, and
replaces `web/org-roam-ui/`. Requires `node` and `npm`.

## Architecture

```text
org-roam.nvim database
        |
        v
lua/org-roam-ui-nvim/graph.lua
        |
        +--> HTTP server: lua/org-roam-ui-nvim/server.lua
        |       /                 static frontend
        |       /graphdata         graph JSON
        |       /variables         frontend variables
        |       /node/:id          plain org text
        |       /img/:path         local images
        |
        +--> WebSocket server: lua/org-roam-ui-nvim/websocket.lua
                variables
                graphdata
                theme
                command messages
```

Main modules:

- `lua/org-roam-ui-nvim/init.lua`: public setup, commands, lifecycle.
- `lua/org-roam-ui-nvim/graph.lua`: graph serialization and node text extraction.
- `lua/org-roam-ui-nvim/server.lua`: minimal HTTP/static file server.
- `lua/org-roam-ui-nvim/websocket.lua`: native WebSocket protocol server.
- `web/org-roam-ui`: vendored static frontend export.

## Protocol

HTTP endpoints:

```text
GET /                       static frontend index
GET /graphdata              { nodes, links, tags }
GET /variables              frontend runtime variables
GET /node/:id               plain text for note/sidebar preview
GET /img/:encoded_path      local image bytes
```

Graph data shape:

```ts
type OrgRoamGraphResponse = {
  nodes: OrgRoamNode[]
  links: OrgRoamLink[]
  tags: string[]
}

type OrgRoamNode = {
  id: string
  file: string
  title: string
  level: number
  pos: number
  olp: string[] | null
  properties: Record<string, string | number>
  tags: string[]
}

type OrgRoamLink = {
  source: string
  target: string
  type: string
}
```

WebSocket messages sent to the browser:

```json
{ "type": "variables", "data": {} }
{ "type": "graphdata", "data": {} }
{ "type": "theme", "data": {} }
{ "type": "command", "data": { "commandName": "follow", "id": "..." } }
```

Browser commands accepted:

```json
{ "command": "open", "data": { "id": "..." } }
{ "command": "getText", "data": { "id": "..." } }
{ "command": "refresh", "data": {} }
```

## Frontend

The frontend is the static export from upstream `org-roam-ui`, copied into:

```text
web/org-roam-ui
```

It has been patched from the Emacs defaults:

```text
localhost:35901 -> 127.0.0.1:35911
localhost:35903 -> 127.0.0.1:35913
```

The current patch is applied to generated JS. Future work should prefer a
source-level frontend fork or build-time configuration so this is less brittle.

## Testing

Run all tests:

```sh
REPO_ROOT="$(pwd)"
nvim --headless -u "$REPO_ROOT/tests/minimal_init.lua" \
  -c "PlenaryBustedDirectory $REPO_ROOT/tests { minimal_init = '$REPO_ROOT/tests/minimal_init.lua' }"
```

Expected coverage:

- graph serialization
- JSON shape compatibility
- node text extraction
- HTTP endpoint handling
- static frontend serving
- WebSocket accept key and frame encode/decode
- command registration

Live backend smoke test:

```sh
nvim --headless -i NONE \
  "+lua local orui=require('org-roam-ui-nvim'); orui.setup({open_on_start=false}); orui.start(); local done=false; local res=nil; vim.system({'curl','-fsS','http://127.0.0.1:35911/graphdata'},{text=true},function(o) res=o; done=true end); vim.wait(10000,function() return done end); orui.stop(); assert(res and res.code == 0, res and res.stderr or 'curl did not finish'); local data=vim.json.decode(res.stdout); print(('nodes=%d links=%d tags=%d'):format(#data.nodes,#data.links,#data.tags))" \
  +qa
```

## Development Notes

- Do not call `org-roam.nvim` synchronous database methods directly from libuv
  fast-event callbacks. Schedule back onto the main loop first with
  `vim.schedule()`.
- Empty JSON objects must use `vim.empty_dict()`. Otherwise `vim.json.encode`
  turns empty Lua tables into arrays (`[]`), which breaks frontend assumptions.
- WebSocket frames from browsers are masked. Server frames must not be masked.
- The default ports intentionally differ from Emacs `org-roam-ui` to avoid
  collisions.
- Static frontend tests should check for patched Neovim ports, not just file
  existence.

## Roadmap

- [ ] Vendor patched frontend source directly (remove upstream patch dependency).
- [ ] Implement citation/ref parity where `org-roam.nvim` can expose the data.
- [ ] Add end-to-end browser tests with Playwright.
- [ ] Package as a normal public plugin instead of a local prototype.
- [x] Replace generated-JS frontend patching with a source-level frontend fork.
- [x] Improve heading node `olp` generation.
- [x] Add richer org-roam properties and refs.
- [x] Export live Neovim colorscheme as theme data.
- [x] Auto-follow cursor node on buffer switch.
