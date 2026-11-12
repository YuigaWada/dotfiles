# AeroSpace

Nix manages the AeroSpace app and LaunchAgent. Home Manager links this file
from `~/.zsh/config/aerospace/aerospace.toml` to
`~/.config/aerospace/aerospace.toml`. The configuration keeps
the helper script in `/run/current-system/sw/bin/aerospace-actions`, so no
user-specific home path is embedded in AeroSpace's bindings. It keeps
Chrome floating and uses AeroSpace workspaces so macOS can still switch
between the Chrome Space and the working Desktop with native gestures.
The default accordion has 80 left/right, 20 top/bottom, and 12 between windows.
AeroSpace's gap settings are global across layouts.
`accordion-padding = 0` aligns all stacked windows at the same position. This
also removes AeroSpace's visible side strips; use `alt-x` / `alt-c` to switch.

Workspace 2 uses side-by-side tiles (`h_tiles`); workspace 3 uses top/bottom
tiles (`v_tiles`); workspace 4 arranges four tiled windows as a 2×2 grid;
workspace 9 uses the original overlapping accordion. The layouts are applied
at startup and when entering each workspace. Additional windows in workspace 4
use AeroSpace's regular tiling behavior.

Active shortcuts:

- `alt-v`: toggle AeroSpace tiles/accordion
- `alt-x` / `alt-c`: previous/next window in tree order
- `alt-h/j/k/l`: directional focus; `alt-shift-h/j/k/l`: move window
- `ctrl-shift-a/x/s/c/e/q/d`: focus a running app without launching it
- `ctrl-shift-left/right`: previous/next AeroSpace workspace (wraps at the ends)
- `ctrl-shift-[/]`: previous/next tab of the focused app (Yuwai Tabs)
- `ctrl-shift-o/z`: save and recall the focused app
- `ctrl-shift-1..9`: move the focused window to an AeroSpace workspace
- `alt-1..9`: focus an AeroSpace workspace

The numbered AeroSpace workspaces are distinct from *native* macOS Spaces.
Yuwai Tabs groups windows of the same app in a nested AeroSpace accordion and
draws a small clickable, draggable tab strip above the focused group. Chrome
remains floating on native Desktop 1.

Nix builds Yuwai Tabs from `~/.zsh/programs/yuwai-tabs`, and Home Manager
installs its signed app at `~/Applications/Yuwai Tabs.app`. Its user LaunchAgent
starts at login and idles until AeroSpace starts. To control AeroSpace:

```sh
yuwd restart aerospace
yuwd stop aerospace
yuwd start aerospace
```
