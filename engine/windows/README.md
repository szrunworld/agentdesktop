# Agent Desktop for Windows

The Windows backend of Agent Desktop: virtual screens with no hardware behind them,
so an agent can run and test programs there while you keep your own screen,
pointer and focus. It mirrors the macOS app and its `agentdesktop` command,
JSON output included.

## Requirements

- Windows 10 or 11, x64
- The [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver)
  (MIT), which provides the monitors
- The .NET 8 SDK, only to build

## Install

As administrator:

```powershell
.\scripts\install-driver.ps1        # or use the driver project's own installer
.\AgentDesktop.Host.exe --setup    # once, if the driver's settings are not writable
```

## Build

```bash
dotnet test tests/SecondScreen.Tests
dotnet publish src/SecondScreen.App -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -o artifacts/publish     # AgentDesktop.Host.exe
dotnet publish src/SecondScreen.Cli -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -o artifacts/publish     # agentdesktop.exe
```

It also builds on macOS and Linux (`EnableWindowsTargeting`); only running
needs Windows.

## Using it

Run `AgentDesktop.Host.exe`, which lives in the notification area. By default
there are two screens: your real one, and **your second screen**, a virtual
display to its right that matches it pixel for pixel. Agents add **agent
screens** of their own when they need them. The menu (in Chinese on a
Chinese Windows) has a section for each:

- **My Second Screen**: turn it on or off, pick its **Resolution**, choose
  how to **View** it, send the front window there or bring it back
  (Ctrl+Alt+Win+M), and bring back any window on it.
- **Agent Screens**: the screens agents have open, each with a preview,
  its windows, and **Close This Screen**.

**View** offers **Full Screen on Its Own Desktop**, the counterpart of a
macOS full-screen Space: agentdesktop adds a virtual desktop after yours with
the screen covering the main display, so a four-finger swipe (or
Ctrl+Win+Right) shows it. The desktop goes away with the view. Windows
desktops span every display, unlike macOS Spaces, so windows on agentdesktop's
screens are set to show on all desktops while they are there; otherwise the
preview's desktop would show the screen empty. Creating it
uses an undocumented shell interface checked against Windows 11 24H2 and
25H2; elsewhere the view falls back to a **Preview Window**.

Agents use `agentdesktop.exe`, or `agentdesktop mcp` for the same commands as MCP
tools:

```powershell
agentdesktop screen create --name test --size 1280x800 --ttl 30m
agentdesktop app launch --screen test --path C:\path\to\App.exe
agentdesktop state --screen test --pid 1234
agentdesktop click --screen test --pid 1234 --text "Press me"
agentdesktop click --screen test --pid 1234 --text "File" --right      # or --double
agentdesktop scroll --screen test --pid 1234 --index 5 --direction down --amount 5
agentdesktop drag --screen test --pid 1234 --from-x 2200 --from-y 500 --to-x 2500 --to-y 600
agentdesktop screenshot --screen test --output shot.png
agentdesktop screen destroy test
```

Output is JSON, in UTF-8 when piped; in Windows PowerShell set
`[Console]::OutputEncoding = [Text.Encoding]::UTF8` first.
`agentdesktop --help` lists everything; `agentdesktop doctor` reports the displays,
and the driver's outputs and topology paths.

Programs start without activation, and `state`, `click`, `type`, `key`,
`scroll` and `drag` refuse a window that is not on the named screen, so your
foreground window stays put. They work in the background, and each result
names the `route` it took:

- **`uia.*`**: UI Automation patterns (invoke, toggle, select, expand, value,
  scroll), which reach a control without any input. A click on an element
  with a pattern, and scrolling an element, go this way.
- **`edit.replacesel`, `uia.value`**: typing into a named text box inserts at
  its caret, or appends to its value; either counts only if the value shows
  the text afterwards.
- **`post.*`**: mouse, wheel and key messages posted to the deepest child
  window under the point, or to the focused control. Text goes as characters,
  so any script works without an input method. While they arrive the window
  cannot activate, and if the program brings itself forward anyway, your
  window goes back in front.
- **`post.key+state`**: for shortcuts such as ctrl+a, posted modifier keys
  are not enough, since programs read held keys from their input state; so
  agentdesktop joins the program's input queue for the moment of the key and
  marks the modifiers held there.

WPF and Chromium (Chrome, Edge, Electron) draw their own controls and read
the real keyboard and mouse for some things, so the routes differ there:

- Typing into a web field writes its value through UI Automation, and
  scrolling a page sets its position when it ignores the wheel.
- A wheel at a point scrolls what lies under it through UI Automation, since
  WPF sends the wheel to whatever is under the real pointer.
- Shortcuts (ctrl+a and the like) in WPF and Chromium are refused in the
  background, with a message saying so: they read held modifiers from the
  real keyboard. `key --foreground` brings the program to the front for the
  moment of the keys and puts your window back.

For anything else a program ignores in the background, `key`, `scroll` and
`drag` take `--foreground`, which brings the program to the front and uses
the real keyboard or pointer; agentdesktop puts the pointer and your window
back afterwards. The end-to-end test covers a WinForms, a WPF and an Edge
window.

### Vision agent

`agentdesktop agent` runs an instruction with a UI-TARS vision model, as on
macOS: the model reads screenshots of the screen and acts by sight through
the commands above, only in the program you name.

```powershell
agentdesktop agent --screen test --pid 1234 "Open Settings and read the version"
```

It needs a model behind an OpenAI-compatible API, by default Doubao Seed
2.1 lite on Volcengine Ark: set `AGENT_MODEL_API_KEY` (and optionally `AGENT_MODEL`,
`AGENT_MODEL_BASE_URL`), or put them in `%USERPROFILE%\.config\agentdesktop\model.env`.
It stops before anything that would send unless given `--allow-submit`
(Enter, typed text ending in a newline, a click on Send, or a click its
reply describes as sending), and before shortcuts that close or switch
programs (alt+f4, alt+tab, Windows-key shortcuts).

## How it works

- **Monitors.** The driver builds its monitors from
  `C:\VirtualDisplayDriver\vdd_settings.xml`, and reloading it tears every
  virtual monitor down. So agentdesktop reserves a pool of three once (its own
  screen and two agent screens; `VirtualDisplayDriver.PoolSize`), with
  common resolutions, then attaches and detaches pool monitors through the
  display topology API (`SetDisplayConfig`), which leaves the others alone.
- **Refresh rates.** The driver multiplies every resolution by every global
  refresh rate and creates no monitor once that passes about a hundred
  modes. Its installer lists six rates, so agentdesktop keeps only 60 Hz.
- **Idle monitors.** Windows extends or clones the desktop onto every new
  monitor by itself. After a reload agentdesktop detaches the ones no screen
  uses; a clone reports the other display's adapter, so they are matched by
  monitor device path.
- **Scale.** A screen is a size in physical pixels plus a scale, set through
  the same undocumented DisplayConfig call Settings uses. By default, and
  with **Resolution > Match**, it copies the main display's pixels and scale
  (say 1920x1080 at 150%), so a full-screen preview there is one to one. A
  `--hidpi` screen has twice the pixels of its `--size` at 200%.
- **Coordinates.** Frames are physical pixels on the virtual desktop, the
  space UI Automation and Win32 use (macOS reports points).

## Tests

- `tests/SecondScreen.Tests`: unit tests, run anywhere.
- `scripts/e2e.ps1`: end-to-end acceptance against `tests/TestTarget`. It
  must run in an interactive desktop session, since services and SSH
  sessions have no desktop.
- `.github/workflows/windows.yml` runs both on a hosted runner, which gets
  real virtual monitors too. Where no virtual monitor can attach, the e2e
  test stands in the main display for the agent screen and skips the checks
  that need a real one.
