# Maki Minimap

A toggleable four-column chat-history rail for [Maki](https://github.com/tontinton/maki) v0.7.0 and newer. It marks genuine user prompts, shows the visible transcript viewport, and jumps between prompts without taking keyboard focus.

The package works with stock Maki v0.7.0 using proportional, **approximate** navigation. Apply the separate core patch for exact rendered anchors and exact navigation. The plugin selects exact mode automatically when `maki.fn.transcript_anchors` is available.

## Install

### Managed package

Add this to `~/.config/maki/init.lua` and restart Maki:

```lua
maki.pack.add({
  "https://github.com/iko-soy/maki-minimap",
})
```

Approve the package and its `session_read` permission when prompted. `plugin.toml` requests only:

```toml
min_maki_version = "0.7.0"

[permissions]
session_read = true
```

The permission is required to read prompts and, with the core patch, transcript previews. The plugin does not request filesystem, network, process, agent, or session-write access.

### Manual package

Install the repository as `maki-minimap` under Maki's package start directory:

```sh
mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/maki/site/pack/local/start"
ln -s /absolute/path/to/maki-minimap \
  "${XDG_DATA_HOME:-$HOME/.local/share}/maki/site/pack/local/start/maki-minimap"
```

Manually installed packages receive exactly the permissions in `plugin.toml`. Run `/reload` after installation or edits. See Maki's package guide if your data directory differs.

## Commands and keys

| Action | Command | Default key, normal and insert modes |
| --- | --- | --- |
| Toggle the rail | `/minimap` | `<M-m>` |
| Next user prompt | `/minimap-next` | `<M-n>` |
| Previous user prompt | `/minimap-prev` | `<M-p>` |

`●` marks a user prompt. `▐` is the viewport thumb. The split opens with `focus = false` and claims no window keys, so typing and normal transcript scrolling remain in the chat. Navigation commands work while the minimap is enabled. Boundaries and unavailable UI state produce a short error message instead of throwing.

### Configuration

The package entry point calls `require("minimap").setup()` with defaults. To customize it, declare the package with a load function:

```lua
maki.pack.add({
  {
    src = "https://github.com/iko-soy/maki-minimap",
  },
}, {
  load = function()
    require("minimap").setup({
      enabled = true,
      width = 4,
      poll_ms = 225,
      keys = {
        toggle = "<M-m>",
        next = "<M-n>",
        previous = "<M-p>",
      },
    })
  end,
})
```

Options:

- `enabled`: open on startup. Default `true`.
- `width`: rail columns, clamped to 3–5. Default `4`.
- `poll_ms`: viewport polling interval, clamped to 200–250 ms. Default `225`.
- `exact`: omit for automatic API detection. Set `exact = false` to force the proportional fallback on a patched Maki.
- `keys.toggle`, `keys.next`, `keys.previous`: Maki key notation. Set an individual key to `false` to leave it unbound.

Repeated setup cleans up the previous windows, poller, autocmds, and keybindings before applying new options. `/reload` performs the same cleanup through Maki's plugin lifecycle.

## Stage 1: stock Maki, approximate navigation

The pure-Lua path uses only Maki's public v0.7.0 API:

- `maki.session.messages({ session = id })` with `session_read`.
- `maki.ui.buf({ scratch = true })`, `Buf:set_lines()`, and a nonfocused right split.
- `maki.fn.winsaveview()` for the rendered row count and viewport.
- `maki.fn.winrestview({ topline = ... })` for scrolling.
- Turn, tool, compaction, input, session-focus, and task-focus autocmds plus a cancellable 225 ms viewport poller.

Only messages with `role == "user"`, `kind == "turn"` or an absent `kind` (Maki's default turn), and `display_text ~= ""` become markers. Prompt positions and jump targets are proportional to raw message indexes and the current rendered row count. **These positions and jumps are approximate.** Variable-height answers, tools, images, wrapping, and expanded blocks can make a jump land away from the requested prompt. The plugin does not duplicate Maki's renderer to guess wrapped rows.

The approximate rail is hidden on subagent chats because `maki.session.messages()` describes the parent session rather than the focused subagent transcript. It returns on the main chat.

History reads happen initially, on prompt/compaction/focus events, and when rendered history shrinks. A restored rewind draft is recognized only when its exact text matches a cached prompt, so normal typing does not cause full-history reads. Proportional anchors are rebuilt only when prompts or rendered row count change. Buffer writes happen only when marker or thumb geometry changes.

## Stage 2: exact navigation core patch

The patch applies to Maki v0.7.0:

```sh
git clone --branch v0.7.0 --depth 1 https://github.com/tontinton/maki.git
cd maki
git apply /absolute/path/to/maki-minimap/patches/maki-v0.7.0-transcript-anchors.patch
cargo install --locked --path .
```

Restart with the patched binary. Exact mode is detected automatically; no plugin setting is required. Rebase the patch for later Maki versions rather than assuming it applies unchanged.

To revert the source change:

```sh
git apply -R /absolute/path/to/maki-minimap/patches/maki-v0.7.0-transcript-anchors.patch
```

Then rebuild Maki. Stock Maki remains supported through `exact = false` or automatic fallback when the API is absent.

### Added APIs

`maki.fn.transcript_anchors()` requires `session_read` and returns actual message segments from the focused display transcript:

```lua
{
  message_index = 3, -- one-based display-transcript index, not a raw session index
  role = "user",
  preview = "first 80 Unicode characters of the first line",
  topline = 41,      -- one-based exact rendered row
  height = 4,        -- exact segment height at the current width
}
```

Indexes refer to Maki's display messages, including assistant, thinking, notice, and other visible roles. Filter `role == "user"` for prompt navigation. Hidden messages and observations remain excluded by Maki's existing history-to-display conversion.

`maki.fn.winrestview({ message_index = ... })` scrolls to the first segment with that display index. Existing `{ topline = ... }` calls are unchanged. A stale display index does nothing.

`maki.fn.winsaveview()` adds:

- `width`: the transcript layout width.
- `anchor_revision`: a hexadecimal token for message-index, role, row, height, and width changes. It contains no prompt text hash. Polling compares this token before requesting anchor tables again.

The implementation reuses `Segment.msg_index`, `SegmentCache`, `Layout::segment_rows()`, and `MessagesPanel::scroll_to_segment()`. Exact mode also works on focused subagent transcripts.

## Tests

Run the dependency-free Lua suite from the repository root with Lua 5.4+ or LuaJIT:

```sh
lua tests/run.lua
```

Or use the Nix test command used during development:

```sh
nix shell nixpkgs#lua -c lua tests/run.lua
```

The suite covers prompt extraction, exact-anchor conversion, proportional calculations and clamping, marker/thumb geometry, empty/short/10,000-message histories, collisions, rapid navigation, explicit fallback, session ownership, subagents, permission/UI errors, redraw suppression, rewind detection, and repeated toggle/setup/reload cleanup.

After applying the core patch, run its tests from the Maki checkout:

```sh
cargo test -p maki-lua --lib 'r#fn::tests'
cargo test -p maki-ui --lib components::messages
cargo check -p maki-lua -p maki-ui --all-targets
cargo clippy -p maki-lua -p maki-ui --all-targets -- -D warnings
cargo run -p maki-docgen -- --check
```

`CARGO_BUILD_JOBS=1` can reduce linker memory and disk pressure on smaller machines. Use Maki's full workspace checks for upstream submission.

Build Maki with `cargo build -p maki`, then run the credential-free pseudo-terminal checks from this repository. Replace the binary path if it is outside `.upstream/maki`:

```sh
python3 tests/tui_smoke.py \
  --maki .upstream/maki/target/debug/maki \
  --package . --work .test-home/exact --mode exact
python3 tests/tui_smoke.py \
  --maki .upstream/maki/target/debug/maki \
  --package . --work .test-home/fallback --mode fallback
```

The helper imports 30 synthetic user turns into an isolated temporary home, captures the TUI, and checks loading, exact or proportional navigation, draft preservation, input focus, resize, and reload. It requires only Python's standard library and never reads the normal Maki configuration or credentials.

## Verification results

Executed successfully:

- **29 Lua tests**, including a 10,000-message history and real v0.7.0 export shapes with omitted `kind` fields.
- **55 `maki-lua` API tests** and **189 `maki-ui` message tests**, including exact anchors, indexes, rows, heights, permissions, revisions, and message targets.
- `cargo check` and `cargo clippy` for `maki-lua` and `maki-ui` with all targets and warnings denied.
- Rust formatting, StyLua checks, generated Lua API doc checks, and clean-clone `git apply --check` for the standalone patch.
- Pseudo-terminal exact mode: load, exact user-anchor targeting, previous/next navigation, unpinning, draft and input-focus preservation, resize, reload, rail glyphs, and no plugin errors.
- Pseudo-terminal forced-fallback mode: the same lifecycle, navigation, focus, resize, and reload checks with proportional jumps.
- The final TUI runs started no agent turns and used only a loopback mock provider.

The full Maki workspace test suite was not run; verification was scoped to the changed crates. These scenarios remain for a live interactive session and are not claimed as verified:

- Streaming model responses and bottom auto-scroll re-pinning after navigation.
- Long tool outputs and interactive tool/thinking expansion and collapse.
- Compaction and interactive history rewind.
- Session tabs and subagent focus outside the fake-host tests.
- Rapid-navigation stress and performance profiling on very long rendered sessions.

## Manual TUI checklist

Check these behaviors in exact and forced-fallback modes where applicable:

- Load and `/reload` with no plugin errors.
- Toggle repeatedly while typing in normal and insert modes.
- Rapid next/previous navigation and bottom auto-scroll.
- Terminal resizing and text rewrapping.
- Long tool output and expanded/collapsed tool or thinking blocks.
- Streaming responses, compaction, and history rewind.
- Session tabs and main/subagent chat focus.
- Very long sessions with no visible input lag or idle redraw activity.
- No click action on the rail, and no keyboard focus taken by it.

Results from automated pseudo-terminal smoke checks are recorded under **Verification results**. Checks requiring a live model session are identified separately from checks fully exercised locally.

## Limitations

- Stock-Maki positioning and navigation are approximate. Use the patch for exact behavior.
- Prompts that map to the same rail row share one visible cell. Navigation still retains prompt identity, but a proportional jump between collided prompts may not move the viewport.
- The approximate rail is intentionally hidden on subagent chats. Exact mode supports them.
- Viewport changes can take one polling interval to appear. There is no tight render loop.
- Mouse click-to-jump is not implemented. Unfocused Lua splits do not receive ordinary clicks in v0.7.0, and this package does not add a broad mouse-routing change. Hover previews and drag scrubbing are also out of scope.
- The core patch targets v0.7.0 and needs review/rebasing for later versions.

## Files

- `plugin/minimap.lua`: package entry point.
- `plugin.toml`: minimum Maki version and permissions.
- `lua/minimap/core.lua`: pure extraction, geometry, clamping, and target selection.
- `lua/minimap/render.lua`: styled rail lines and redraw signatures.
- `lua/minimap/runtime.lua`: windows, focus, polling, navigation, and cleanup.
- `lua/minimap/init.lua`: public setup and command functions.
- `tests/`: pure and fake-host Lua tests.
- `patches/maki-v0.7.0-transcript-anchors.patch`: standalone Maki core change and Rust tests.
