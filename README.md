# IBOVmap

A standalone track map for Assetto Corsa (Custom Shaders Patch) streams and broadcasts. It is the Broadcasting app's
track map on its own: live car indicators coloured by class or relative to the focused car, position and name labels,
sector markers, a northpoint, the name of the corner the focused car is in, and optional class names from an AC Server
Manager (ACSM) live-timing feed.

## Requirements

- Assetto Corsa with [Custom Shaders Patch](https://acstuff.club/patch/). The map uses the same CSP APIs as
  Broadcasting, which is tested on CSP 0.2.11 and 0.3.1.

## Installing

1. Copy the `IBOVmap` folder into `assettocorsa\apps\lua\`, so that you have `assettocorsa\apps\lua\IBOVmap\manifest.ini`.
2. Start a session and open **IBOVmap** from the apps sidebar. **IBOVmap Settings** is reached through the app's
   settings icon.
3. Hover the map to move or resize it (its resize grip also shows while settings are open). Click a car's indicator to
   spectate it; hover one for its position, driver and class.

All settings save automatically. Settings are in five tabs: **Map**, **Style**, **Classes**, **Drivers** and **Presets**.

## Views

**Track** follows real X/Z world coordinates. Artwork can use the current layout's `map.png` calibrated by
`data\map.ini`, with a generated AI-spline fallback, or use the generated spline explicitly. The generated view is the
fast-lane centreline, not a reconstruction of kerbs, pit roads or track edges. Generated lines (spline, Linear and
Circular) take an optional border width and colour; `map.png` artwork is drawn as-is. The Track view can be turned to
any angle with the rotation dial, or turn with the focused car so it always travels up the screen.

**Linear** and **Circular** plot normalised spline progress rather than world position. Circular joins the ends
visually even on A-to-B tracks; distances on those tracks do not wrap. The small cross-track tick marks the start.

Focus zoom 0 fits the whole map; 1 shows a 100 metre radius on the shorter window axis around the focused car.
Intermediate zoom is continuous. Linear and Circular instead show a focused 200 metre spline segment at maximum zoom.
Tracks shorter than 200 metres keep their full scale. Without an active, connected focus, the whole track is shown.
An optional edge fade softens the window's edges without fading the whole-track view's contents.

If artwork or calibration is missing, settings explain the spline fallback. Invalid calibration or spline data is
logged. If neither source is available, the Track view says so; Linear and Circular remain available.

## Cars

Disconnected and inactive cars are never plotted, and drivers listed under **Drivers > Exclude names** are left off
the map and out of its positions (a TV car, or your own car while spectating).

Positions follow the race order as Broadcasting's standings work it out: grid order before a race start, CSP's race
order during it, and the order cars took the flag. A car that leaves mid-race is held where it was until another car
covers more distance; it gets no indicator but still counts towards class positions. In replays, where CSP keeps lap
counts only for the recorded car, every car's laps are rebuilt from its lap timer. Outside races, cars are ordered by
best lap.

The indicator label (and the optional name tag beside each indicator) can be none, overall position, position within
class (counted among connected, non-excluded drivers; unclassified cars keep overall positions), the first two letters
of the driver's name, the first two or three letters of their surname (the last word of the name), their initials (up
to three words), or the car's livery number (blank when it has none). Driver letters are uppercased and skip leading
punctuation. Ctrl+drag any name tag to move every tag to that spot beside its indicator.

Indicators can use uniform, class or focused-car-relative colours, and the race leader can take a colour of its own.
Relative race colours compare completed laps plus spline progress, so crossing the start line does not spuriously
classify a nearby car as a lap ahead. At least one full lap of progress separates the lap-ahead/behind colours.
Outside races, relative colours use the nearest direction around a closed track, with no lap-ahead/behind
classification.

The focused car is highlighted, enlarged and drawn last. Teardrop and triangle pointers follow the car's heading on the
Track view, and spline direction in Linear/Circular. Set radius, border, shadow, fonts, label colours and an optional
texture independently; the texture overlays the shape, and transparency reveals its class/relative colour.

Class colours come from the Commodore 64 palette (minus black and white): classes defined in the Classes tab take
colours in their order there, and other labels (such as live-timing classes) the next unused one, so 14 classes are
distinct before any repeat. A join never recolours a class. Per-class overrides are under **Map > Class colours**. An
optional legend identifies the class or relative colours; Ctrl+drag it anywhere on the map.

## Track features

- **Sector markers**: a tick across the track at each sector split, from the track's timing gates. On a track without
  them, each split is learnt the first time a car crosses it and kept for that track.
- **Northpoint**: a compass rose pointing to the track's north (from CSP's compass), turning with the map. An image
  (north at the top, east to the right) can replace it.
- **Corner names**: like Kunos's Track Description app, the name of the corner the focused car is in fades in, holds a
  moment after it leaves, and crossfades to the next. Names come from the track's own `data\sections.ini`, unless this
  app's folder has `sections\<track>.ini` (or `sections\<track>_<layout>.ini`) for the track, which takes its place.
  Both use the `sections.ini` format: `IN` and `OUT` as lap fractions, and the name in `TEXT`. While the Corner names
  section of settings is open, a placeholder shows where the name will appear.

The legend, corner name and northpoint can each be Ctrl+dragged anywhere on the map (a plain drag moves the window).
Where you drop them, and learnt sector splits, are kept for each track.

## Classes and ACSM integration

Classes are defined in the **Classes** tab by car tags (from each car's `ui\ui_car.json`) and, optionally, exact driver
names; a driver assignment beats car tags, and if a car matches several classes the highest one wins.

For server classes instead, open **Classes > ACSM integration** and paste any page URL from your AC Server Manager
site, including its `?server=` value when applicable. Public access to **Live Timing > API List** is required. When
the leaderboard lists ClassIDs, those classes are used for every driver it lists, and the app's own classes apply to
drivers missing from it (for example, those who joined since the last fetch).

For unnamed classes, IBOVmap probes `/api/championships/list.json` and checks championships with `progress < 100`.
Class UUIDs in their standings identify class names directly; if names remain unresolved, championship `/export`
endpoints are tried for `Classes[].ID` and `Name`. Exports can be several megabytes. Requests are sequential and stop
once every missing class name is found. Discovered names are saved in the class-name fields and can be edited; saved
names are never overwritten. Unresolved classes show as `Class n`. **Fetch now** retries; changing the URL starts a
fresh probe.

## Presets

**Presets** save every setting (map, style, classes and drivers) and, when the map is open, its position, size and
pinning. Presets are kept in `presets.json` in this app's folder; referenced images and fonts are not copied. A
preset with damaged classes or window geometry is not applied at all. **Recover map window to screen** brings a lost
window back.

## Images

Indicator textures and northpoint images take an absolute path or one relative to this app's folder. SVG files are
drawn once into a cached PNG (in `.cache\svg`): shapes, paths, strokes, gradients, opacity and CSS are drawn; text,
embedded images, clipping, masks, patterns and filters are not, so convert text to paths first. **Map > Images >
Reload images** picks up changed files.

## Performance

No connection event reinitialises the map, reloads files or rebuilds geometry. Each draw resolves current car states
from the polled standings order, so joins appear after the next car-data poll. Movement is sampled live for smooth
rendering. Geometry is loaded once per track/layout or explicit reload, starting when the map is first drawn, and
sampled in batches capped at 32 points and a 0.5 ms work budget per update. Track artwork is cached by CSP.

Drawing is designed to allocate almost nothing per frame. The generated line is projected to screen space only when
the view moves, points under 2 px apart are dropped, and zoomed views skip off-screen stretches in 32-point chunks.
Text is the main fixed cost, at one DirectWrite call per label: choosing "None" for labels and name tags and hiding the
legend saves it. The car-data, reorder and livery-number intervals are under **Drivers > Data refresh**.

## Relationship to Broadcasting

IBOVmap carries only what the map needs from Broadcasting: the map itself, the standings order behind its positions,
classes with ACSM live timing and class discovery, driver exclusions, font lists, SVG images and presets. Its settings
are its own; it does not read Broadcasting's settings, presets or themes. Themes are not supported, and the camera cone
shown during Broadcasting's empty-track tour is not included.

## Validation

From this app folder, run:

```text
lua tests\ibovmap.lua
```

These are Lua/CSP-stub tests of IBOVmap's own wiring (standings order, corner names, presets, live timing and the
windows). Visual alignment and frame-time behaviour still need checking in AC on the intended track/layout, including an
online join, driver swap, focus change and replay rewind.

## Licence

GNU General Public License v3.0; see [LICENSE](LICENSE). IBOVmap is derived from the Broadcasting app, which is
distributed under the same licence.
