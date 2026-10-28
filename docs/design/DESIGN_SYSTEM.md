# Danaview design system: UI and UX rules

Owner decision 2026-10-28: the indigo theme is retired. Danaview uses **Cinema B**: true black,
deep red, hairline depth and iOS-standard rounding. The logo is the 6B page-fold mark recoloured
as **R3** (black tile, white page, red fold).

This file is the source of truth for every screen on every platform (iOS, iPadOS, Android,
macOS, Windows, Linux). Code reads the values only through the kit tokens in
`packages/danaview_ui_kit/lib/src/theme/` (`DanaviewColors`, `DanaviewRadius`, `DanaviewBorders`,
`DanaviewShadows`, `DanaviewSpacing`, `DanaviewTextStyles`). No screen hard-codes a hex value,
radius or shadow.

---

## 1. Principles

1. **Content first.** Photos, videos and documents carry the colour. Chrome stays black and grey.
2. **One accent.** Red marks the single most important thing on a screen: the selected tab,
   the primary button, progress, links. It is never decoration.
3. **iOS-native feel on every platform.** Large titles, grouped lists, capsule tabs and continuous
   corners. Android and desktop get the same look; only system behaviours differ (back gesture,
   menus, keyboard).
4. **Quiet depth, no outlines.** Surfaces separate through tone, a near-invisible hairline and
   a soft top highlight. They never use a coloured or bright border.
5. **Full width, no dead space.** No max-width caps. Sparse lists wrap into grids, and related
   controls sit close together.

---

## 2. Colour (Cinema B)

### 2.1 Surfaces and text

| Token | Hex | Use |
|---|---|---|
| `background` | `#000000` | Screen background (true black, OLED) |
| `surface` | `#141414` | Cards, grouped lists, the tab bar |
| `surfaceElevated` | `#222222` | Raised items on a card: idle tab pills, fields, secondary buttons, toasts |
| `surfaceElevatedHigher` | `#2A2A2C` | Icon tiles, menus, popovers |
| `scrim` | `#000000` at 60 % | Behind sheets and dialogs |
| `textPrimary` | `#FFFFFF` | Titles, body |
| `textSecondary` | `#9A9A9A` | Metadata, idle tab labels, counts |
| `textMuted` | `#6E6E6E` | Placeholders, disabled labels, chevrons (`#5A5A5A`) |

### 2.2 Accent

| Token | Hex | Use |
|---|---|---|
| `primary` | `#B20710` | Selected tab, primary button, progress fill, slider track, switch on |
| `onPrimary` | `#FFFFFF` | Text and icons on `primary` (contrast 7.2:1) |
| `primaryLight` | `#F2444D` | Accent **text and icons on dark**: links, section actions, the selected tab-bar item, active toolbar icon |
| `primarySoft` | `#B20710` at 16 % | Selected row wash, keyboard focus fill |
| `focusRing` | `#F2444D` at 55 % | Keyboard-only focus ring (2 pt) |

Rules:
- At most **one filled red control per view**. Siblings are `surfaceElevated` with white text.
- Never put `primary` text on black: it fails contrast. Use `primaryLight` instead.
- The selected tab-bar item uses `primaryLight`; idle items use `#8A8A8A`.

### 2.3 Status

Red is the accent, so errors are **not** red.

| Token | Hex | Use |
|---|---|---|
| `success` | `#30D158` | Saved, done, connected |
| `warning` | `#FFD60A` | Unsaved, attention, low storage |
| `error` | `#FF9F0A` | Failed, invalid input, clipping on audio meters |
| `destructive` | `#F2444D` | Delete and remove actions: always with a trash icon and a confirm dialog |

- A status colour appears as a **dot or icon plus words**. It is never a border or a full-card fill.
- Banners use the status colour at 14 % on `surfaceElevated`, with the text in `textPrimary`.

### 2.4 Product accents (logo flap only)

Player `#E50914`, Editor `#8B5CF6`, Camera `#06B6D4`, Photos `#F59E0B`, Docs `#10B981`.
These colour **only the fold of the product's logo**. Inside the app UI everything uses the one red
accent.

### 2.5 Media placeholders

When a thumbnail is still loading, it shows a neutral `#1C1C1E` tile with a centred 20 pt
type icon in `textSecondary`. There are no coloured or gradient placeholders.

---

## 3. Borders, depth and elevation

"Hairline depth" makes surfaces feel semi-3D without visible outlines.

| Layer | Recipe |
|---|---|
| Hairline | 0.5 pt, white at **7 %** (`hairline`). Inner tiles on a card use 5 %. |
| Top highlight | 1 px inner line along the top edge, white at **6 %** (cards), **12 %** (icon tiles), **18 %** (primary button) |
| Card shadow | `0 1 2 #000 @60 %` + `0 8 20 #000 @35 %` (`DanaviewShadows.card`) |
| Raised button shadow | `0 2 8 #000 @50 %` (primary only) |
| Dividers in lists | 0.5 pt, white at 6 %, inset to start after the icon tile |

Rules:
- **No bright, accent or status outlines** anywhere (owner rule). The only coloured edge is the
  keyboard focus ring.
- **No hover or press tints, and no scale animations** on controls (owner decision A). Keyboard
  focus is the only interactive visual state.
- Selection rings around thumbnails are **never clipped** by the cell: draw them outside the
  content with room. Strips and rows are clipped to their panel's rounded shape.
- Nesting: `background` → `surface` (card) → `surfaceElevated` (item on a card) →
  `surfaceElevatedHigher` (menus, icon tiles). Never put two surfaces of the same level inside
  each other.

---

## 4. Corner radius (iOS continuous corners)

Use smooth "squircle" corners (`RoundedSuperellipseBorder`, or `ContinuousRectangleBorder`
tuned to the same visual size), not plain circular arcs.

| Token | Radius | Elements |
|---|---|---|
| `xs` | 6 | Badges, duration labels on thumbnails, small chips |
| `tile` | 8 | 28 pt icon tiles in lists |
| `thumb` | 10 | Thumbnails inside a card, timeline clips |
| `control` | 12 | Buttons, text and search fields, the filter button, grouped lists |
| `media` | 14 | Media cards (Continue watching, projects), photo strip container |
| `card` | 16 | Large cards and panels |
| `toast` | 20 | Toasts, snackbars, popovers |
| `sheet` | 24 | Bottom sheets and dialogs (top corners only on sheets) |
| `capsule` | full | Tab pills, chips, segmented controls, round toolbar buttons (34 pt circles) |
| app icon | 22.37 % of the side | Logo tile (iOS icon mask) |

Inner radius = outer radius − padding (for example a 14 card with 5 padding holds a 10 thumbnail
inside it, rounded 9–10).

---

## 5. Spacing and sizing

Existing `DanaviewSpacing` values stay: 2, 4, 8, 12, 16, 24, 32.

- **Page gutter:** 16 (phone), 24 (tablet), 32 (desktop), via `DanaviewSpacing.pageInsets`.
- **Section spacing:** 24 above a section header, 8 between the header and its content.
- **Grid gaps:** 10 between cards, 3 between photos in a strip.
- **Touch targets** are at least 44 × 44 pt. A visually smaller control (tab pill, 34 pt toolbar
  circle) keeps an invisible 44 pt hit area.
- **Field rows have equal heights.** Search field, filter button and Import button are all
  `controlHeight` (44 pt; the 36 pt visual inside a 44 pt target on compact layouts).
- **Full width everywhere:** no `maxWidth` caps. On wide layouts content splits into columns
  instead of stretching a single list.

---

## 6. Typography

Font: **Figtree** (bundled). The scale follows iOS Dynamic Type sizes and grows with the text
scale up to 1.35 without clipping.

| Style | Size / weight | Use |
|---|---|---|
| `largeTitle` | 30 / 700, tracking −0.5 | Screen title ("Danaview" on Home, "Settings") |
| `title` | 22 / 700 | Sheet and dialog titles |
| `sectionHeader` | 20 / 700 | Section headers on Home and tabs |
| `headline` | 17 / 600 | Card titles, list row titles |
| `body` | 17 / 400 | Body text, list rows |
| `subhead` | 15 / 400 | Secondary row text, section actions (in `primaryLight`, 600) |
| `footnote` | 13 / 400 | Metadata (duration · size) |
| `caption` | 12 / 500 | Badges, duration labels, tab-bar labels (11 / 500) |

- Sentence case everywhere. No ALL-CAPS headers.
- Numbers in metadata use tabular figures.

---

## 7. Icons

- Use **Material Symbols Rounded** (the `Icons.*_rounded` set already in use) at weight 400.
  Don't mix in outlined or sharp sets.
- Sizes are 20 (toolbar, tab bar, list tile glyph 15–16), 24 (empty states inside a 48 tile)
  and 14 (chevrons, inline).
- Colours: `textPrimary` by default; `textSecondary` for chevrons and inline metadata;
  `primaryLight` only for an active or selected state.
- **List icon tiles ("premium"):** a 28 pt tile in `surfaceElevatedHigher` (`#2A2A2C`), radius 8,
  with a 10 % hairline, a 12 % top highlight and a white 15 pt glyph. They are always neutral,
  never coloured squares.
- Toolbar buttons are 34 pt circles in `surfaceElevated`, with a 6 % top highlight and a 17 pt
  glyph. The add/import button's glyph is `primaryLight`.
- Every icon-only button has a tooltip (pointer platforms) and a semantics label.

---

## 8. Components

| Component | Spec |
|---|---|
| **Primary button** | `primary` fill, white 15/600 label, radius 12, 44 pt, 18 % top highlight, raised shadow. One per view. |
| **Secondary button** | `surfaceElevated`, white label, 7 % hairline, 6 % highlight. |
| **Text action** | `primaryLight` 15/600, no background (section headers: "See all", "New", "Add"). |
| **Tab pill** | Capsule, padding 13 × 6; selected `primary` with white 600 label, 12 % hairline and 18 % highlight; idle `surfaceElevated` with `textSecondary` label. Sized to its label; the strip scrolls. |
| **Search field** | `surfaceElevated`, radius 12, search glyph, placeholder "Search videos, photos, docs", mic glyph on iOS. It takes all the width the filter button leaves. |
| **Filter button** | A square the same height as the search field, radius 12, with a `tune` glyph. It opens the filter menu (no inline dropdown). |
| **Grouped list** | A `surface` card, radius 12. Each row is an icon tile, a title, a trailing value in `textSecondary` and a chevron. Inset dividers. |
| **Media card** | A `surface` card, radius 14, padding 5, holding a thumbnail at radius 10. Overlays on the thumbnail: a play disc (30 pt, black 45 %), a duration badge (black 55 %, radius 5) and a 3 pt progress bar (`primary` on white 18 %). Title 1 line, 500. |
| **Photo strip** | Square cells with 3 pt gaps in one container at radius 14, edge to edge. |
| **Toast** | `surfaceElevated`, radius 20, a status dot, the message and a `primaryLight` action ("Undo"). It floats above the tab bar. |
| **Bottom sheet** | `surface`, top radius 24, a grabber (36 × 5, white 30 %), and a large title. |
| **Menu / popover** | `surfaceElevatedHigher`, radius 14, rows 44 pt; destructive rows use `destructive`. |
| **Switch, slider, progress** | The active track is `primary`; the inactive track is white 18 %. |
| **Tab bar (phone)** | `surface` at 92 % with a 7 % top hairline, 4 items, a 20 pt glyph and an 11 pt label; selected `primaryLight`, idle `#8A8A8A`. |
| **Empty state** | A 48 pt neutral icon tile, a 17/600 title, a 15/400 body, and one secondary button. No illustrations. |

---

## 9. Logo: 6B page fold, colourway R3

The shape is unchanged (construction in `assets/branding/BRAND.md`). The colours change:

| Part | Value |
|---|---|
| Tile | Linear gradient `#2A2A2A` → `#0A0A0A` (top-left to bottom-right) |
| Tile edge | 0.5 pt (8/1024 at icon scale), white at 14 % |
| Tile highlight | Top band, white at 5 % |
| Page | `#FFFFFF` |
| Fold (the "v") | `#E50914` (master / Player) |
| Product folds | Editor `#8B5CF6`, Camera `#06B6D4`, Photos `#F59E0B`, Docs `#10B981` |
| Mono glyph | White page; the fold is cut out (no fill) |

- **In the app:** in the top bar the 28–32 pt tile sits left of the "Danaview" large title,
  with a gap of 8. `DanaviewLogoPainter` draws it.
- **Lockups:** wordmark in Figtree 700, white on dark and `#0B0C10` on light. Spacing rules as in
  `BRAND.md`.
- **Don'ts:** don't recolour the page, don't put the tile on red, don't add a play triangle,
  and don't rotate or stretch it.
- **Regenerate everything** with `assets/branding/generate_brand.py`: the icon sets for all
  platforms, the brand sheet, the lockups and the Play feature graphic.

---

## 10. Home structure

### 10.1 Top bar

| Platform | Layout |
|---|---|
| iPhone / Android phone | Logo tile + **Danaview** (large title, collapses to an inline title on scroll), then **Import (+)** on the right. |
| iPad / tablet / desktop | Logo tile + **Danaview**, then the round buttons **Video editor**, **Import (+)** and **Settings** on the right. |

Under the title come the **search field (full width) and the filter button** in one row of
equal heights.

### 10.2 Tab strip

A row of capsules that scrolls sideways when the tabs don't fit:
**Home · All · Videos · Photos · Documents · Playlists · Folders · Projects**. Tabs behind an
off flag are hidden. Arrow keys, Home and End move the selection, and the selected tab
scrolls into view.

### 10.3 Home tab sections (in order)

| # | Section | Header action | Layout |
|---|---|---|---|
| 1 | **Continue watching** | Show all / Clear (menu) | A horizontal row of 16:9 media cards with progress |
| 2 | **Recent photos** | See all | An edge-to-edge square strip (4 on phone, 8 on iPad) |
| 3 | **Projects** (editor flag) | Open projects | A grid of project cards (thumbnail, name, "Edited 2h ago") |
| 4 | **Playlists** | New | A grouped list: icon tile, name, count |
| 5 | **Folders** | Add | A grouped list: "On this iPad/phone", Downloads, cloud folders |
| 6 | **Documents** (Files Home flag) | See all | A grouped list: type tile, name, size |

- A section with no items is **hidden**. Home never shows six empty states.
- If everything is empty, Home shows one empty state with **Open file / Open folder / Open link**.
- **Phone:** the six sections stack in one column.
- **iPad landscape / desktop:** two columns. The left column (≈ 60 %) holds Continue watching,
  Recent photos and Projects; the right column (≈ 40 %) holds Playlists, Folders and Documents.
- **iPad portrait:** one column, with grouped lists side by side in a 2-up grid.

### 10.4 Other tabs

| Tab | Layout |
|---|---|
| **All** | Sort and type chips, then a mixed adaptive grid (2 / 4 / 6 columns by width) with media cards and document tiles. |
| **Videos** | Continue watching at the top, then a grid of 16:9 media cards. |
| **Photos** | A full-width square grid with 2 pt gaps (3 / 5 / 8 columns), grouped by month with sticky month headers. |
| **Documents** | A grouped list (or a 2-up grid on tablets): type tile, name, size, date. |
| **Playlists** | A grid of playlist cards (a 2×2 thumbnail mosaic, name and count); **New** is in the header. |
| **Folders** | A grouped list of sources; tapping a source opens a folder screen with the same grid as All. |
| **Projects** | A grid of project cards; **New project** is the screen's one primary button. |

### 10.5 Phone tab bar

**Library · Editor · AI Studio · More.** Editor and AI Studio appear only when their flags are on;
if both are off, the bar has only Library and More. Settings lives under More on phones. Tablets
and desktops keep the editor and settings buttons in the top bar and have no tab bar.

---

## 11. Motion

- Use durations from `DanaviewMotion`: 150 (fast), 220 (normal), 250 (slow), with the kit curve.
- Allowed: tab-strip selection slide, sheet slide-up, toast fade/slide, the large title collapsing.
- Not allowed: hover or press scaling, bounces, parallax, shimmer.
- When Reduce Motion is on, motion becomes crossfades only.

---

## 12. Accessibility

- Text contrast is at least 4.5:1 (body) and at least 3:1 (large text, icons). Red text on black
  must use `primaryLight`.
- Every target is at least 44 pt; tabs, icons and toggles carry semantics labels and selected
  state.
- Layouts must work at text scale 1.35 and a width of 280 px without overflow.
- Keyboard: Tab order follows the visual order, Enter/Space activate, and the focus ring is
  visible only during keyboard use.

---

## 13. Migration from the indigo theme

| Old | New |
|---|---|
| `background #07080C` | `#000000` |
| `surface #0F1118`, `cardGlass #12141F` | `#141414` |
| `surfaceElevated #181B26` | `#222222` |
| `surfaceElevatedHigher #222636` | `#2A2A2C` |
| `primary #5E60EE`, `primaryDark #4F46E5` | `#B20710` |
| `primaryLight #818CF8` | `#F2444D` |
| `primaryTonal`, `primarySoft` (indigo washes) | red at 22 % / 16 % |
| `focusRing` (indigo 28 %) | `#F2444D` at 55 % |
| `textSecondary #A0A6BC`, `textMuted #8B91A9` (blue-grey) | `#9A9A9A`, `#6E6E6E` (neutral) |
| `error #EF4444` | `#FF9F0A` (orange); `destructive` `#F2444D` |
| `warning #F59E0B` | `#FFD60A` |
| `success #10B981` | `#30D158` |
| `DanaviewBorders.width 0.8`, hairline 8 % | 0.5, 7 %, plus the top highlight |
| radii 6 / 8 / 10 / 14 / 16 / 20 | `xs` 6, `tile` 8, `thumb` 10, `control` 12, `media` 14, `card` 16, `toast` 20, `sheet` 24 |
| `cyan`, `purple`, `boostBand` UI uses | Neutral or `primary`; product hues only on logo folds; the boost band keeps orange/red meaning on the volume slider |

Order of work: change the tokens → add the radius, border and shadow tokens → restyle the kit
components → rebuild the Home layout (§10) → recolour the logo (§9) → regenerate the golden
images → iPad review.
