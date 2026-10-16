# Danaview video editor: user guide

> **For:** Danaview 1.1.0 on iPhone, iPad and Android. **Owner:** INT-05 (BUILD_PLAN INT-05: "features and shortcuts").
> **State:** draft prepared by INT-05-PREP on 2026-10-16 from ARCHITECTURE §17 and the app's own labels. Re-read it against the release build before publishing (a TestFlight or internal-track build with the editor turned on).
> **Not in 1.1:** the editor on Mac, Windows and Linux (coming in 1.3), photo browsing on Home and photo editing (coming in 1.2).

---

## 1. Getting to the editor

- **From Home:** tap the editor button, just left of the settings gear. It opens **Projects**.
- **From the player:** while a video from your device is playing, tap **Edit video** in the top bar (or in the Playback "more" sheet, or press **E** on a keyboard). The editor opens on that video, at the frame you were watching. When you close the editor, the player comes back paused at the same spot. The button is hidden while the player controls are locked.
- **Which devices:** iPhone and iPad on iOS 15 or later. Android 10 or later with at least 2 GB of memory. On older Android phones the editor button still shows and explains why the editor isn't available there; the player works as before.
- **Files the editor can't open:** on iPhone and iPad, MKV, WebM and AVI files play in the player but can't be edited. Danaview tells you when you tap Edit.

## 2. Projects

- **New project:** pick the videos, photos or music to start with.
- **Rename, duplicate, delete:** from a project's menu. Deleting a project removes its own files (recordings, freeze frames, copies of picked media no other project uses). It never touches your original videos, photos or music.
- **Saving:** projects save themselves as you work. The title button at the top shows the save status. **⌘S** / **Ctrl+S** saves right away.
- **If the app closes unexpectedly:** the next time you open Projects, Danaview offers to restore the unsaved changes.
- **Projects from a newer Danaview:** they open read-only, with a note, until you update.

## 3. The editor at a glance

- **Top bar:** close, the project title (tap for project options), undo, redo, export.
- **Preview:** shows the frame at the playhead. Drag, pinch and rotate things right on it. Tap the fullscreen button (or press **F**) for a bigger view.
- **Transport:** play/pause, step a frame, jump to the start or end, current time.
- **Timeline:** your clips on lanes for video, overlays, text, captions and sound.
- **Tools:** along the bottom (phones held upright) or the side (tablets, landscape). Tap a clip and the tools change to what fits that clip.
- **Inspector:** settings for the selected clip or tool, docked so the preview stays visible.

On small screens the layout gives way gracefully: the timeline shrinks first, then the preview, then tool labels turn into icons.

## 4. Working on the timeline

**Touch**
- **Scroll** to move through time. By default the playhead stays centred and the video follows ("Center playhead on touch" in Settings › Video editor).
- **Pinch** sideways to zoom.
- **Tap** a clip to select it. **Long-press** to pick it up and move it, even to another lane.
- **Drag a clip's edge** to trim it.
- Clips **snap** to the playhead, other clips' edges and markers, with a light tap you can turn off in settings.

**Mouse and trackpad**
- **Wheel:** scroll lanes up and down. **Shift+wheel:** scroll through time. **⌘+wheel** / **Ctrl+wheel:** zoom at the pointer.
- **Drag on an empty lane** to select several clips with a box. **Shift-** or **⌘-click** adds or removes a clip from the selection.
- **Right-click** a clip, a lane or the ruler for its menu.
- Hold **Alt** while dragging to stop snapping for that move.

**Editing**
- **Split** at the playhead (**S**). **Delete** leaves a gap; **Ripple delete** (Shift+Delete) closes it. **Delete gap** closes an empty space.
- **Copy, cut, paste, duplicate** clips (⌘C, ⌘X, ⌘V, ⌘D).
- **Ripple editing** (**R**) keeps later clips moving along when you trim or delete.
- **Undo and redo** everything (⌘Z, ⌘⇧Z). **History** in the project options lists the last 50 steps and jumps back to any of them.
- **Markers** (**M**) flag a moment; clips snap to them. Edit or delete a marker from its menu.
- **Add track**, change **track height**, and turn on **safe area guides** from the timeline's menus.

## 5. Media

- **Media** shows what's in the project. Add more from your photo library or Files, place it at the playhead, put it on top as an overlay, or replace a clip's media while keeping its edits.
- **Drag and drop** from Files or Photos straight into the editor on iPad, and on Android tablets from other apps.
- Picked items are copied into Danaview's own storage so the project keeps working. Files from your own folders stay where they are.
- **Missing files:** if a file was moved or deleted, its clip shows as missing. **Relink** points it to the file's new place. **Relink several** finds the other missing files in the same folder at once.

## 6. Sound

- **Add music** to its own lane. **Extract audio** puts a video's sound on a separate clip.
- **Record voiceover:** a short countdown, then it records from the playhead. Recordings stay in the project.
- **Volume:** per clip (up to 200 %), with mute and fade in / fade out. **Keep pitch** keeps voices natural when you change speed.
- Lanes can be muted or soloed.

## 7. Text

- **Add text** at the playhead, then edit it right on the preview.
- **Font:** ten fonts, from clean (Figtree, Inter, Montserrat) to bold (Oswald, Bebas Neue), elegant (Playfair Display, Lora), handwritten (Caveat, Pacifico) and typewriter-like (JetBrains Mono). Other alphabets fall back to your device's fonts.
- **Style, Background, Stroke, Shadow** for color, size, alignment, a box behind the text, an outline and a shadow.
- **Animation:** Fade, Slide (left, up, right, down), Scale or Typewriter, in and out, with a looping preview.

## 8. Captions

- **Captions** opens the caption list: add, edit, retime, split, merge and delete captions, change their style and position.
- **Import** SRT or VTT caption files, and **export** yours as SRT or VTT.
- **Shift all captions** moves a whole caption track earlier or later. **Select all on this lane** grabs every caption at once.
- **Burn in:** each caption track can be drawn into the exported video, or left out and saved as a separate file.

**Auto captions** (iPhone, iPad, and Android phones with a 64-bit processor)
1. Open **Captions › Auto captions**.
2. Pick the **spoken language**, or **Detect automatically** (Danaview listens first and asks if it isn't sure).
3. Pick the **quality**: Fast, Balanced (the default) or Accurate (on devices with enough memory). Choose what to caption: the selected clips or the whole video. Music is left out unless you tick it.
4. **Layout:** Standard (2 lines), Single line or Short phrases. **Advanced** has line length, reading speed and sound descriptions like [music].
5. The first time, Danaview asks before it downloads the speech model (about 31 to 181 MB depending on quality) and shows exactly what it will download and from where. After that, captions are made on your device, even offline. Your video and audio are never uploaded.
6. The captions land on a new caption track as one step, so a single undo removes them all. **Regenerate captions** redoes them with a different layout or quality; if you edited some, Danaview asks first.

Long caption jobs keep going in the background on Android (with a notification). On iPhone and iPad they pause when you leave the app and carry on when you come back. Automatic captions can contain mistakes, so read them before you publish.

## 9. Look and motion

- **Adjust:** light, color and detail controls, with a before/after view and **apply to all**.
- **Filters:** twelve looks (Cinematic, Cool, Fade, Matte, Mono, Noir, Pastel, Sepia, Teal & Orange, Vintage, Vivid, Warm) with an intensity slider, plus **My LUTs** for `.cube` files you import.
- **Transitions** between two clips: Fade, Cross dissolve, Dip to black, Dip to white, Slide, Wipe and Zoom, with direction and duration. **Apply to all cuts** in one go.
- **Speed:** a constant speed or a speed curve. **Reverse** plays a clip backwards. **Freeze frame** holds the frame at the playhead.
- **Transform:** move, scale and rotate on the preview, or type exact values. **Reset transform** puts it back. **Crop** and **Mask** shape what shows.
- **Chroma key** removes a green or blue background (pick the color with the eyedropper, check the matte preview).
- **Overlays:** a video or photo on top of another, with **Bring forward** and **Send backward**.
- **Keyframes:** set position, scale, rotation, opacity and more at different moments; the values move in a straight line between them. **Keyframe at playhead** adds one where you are.

## 10. Project format

**Format** sets the project's shape (such as 16:9, 9:16, 1:1 or 4:5), the background behind clips that don't fill it (a color or a blur), the frame rate and the base resolution. New projects use the default from Settings › Video editor: Match first clip, 16:9, 9:16, 1:1 or 4:5.

## 11. Smooth preview on any phone

- **Preview quality** (the quality menu by the transport): Auto (the default) lowers the preview sharpness under load and brings it back when it can. You can pin Full, Half or Quarter there; Settings › Video editor sets the default for new sessions (Auto, Full or Half). Exports are always full quality.
- **Proxies:** lighter copies of big videos for smoother editing. Settings › Video editor › Proxy media: Auto, Always or Off. Phones with less memory start on Always.
- **Render preview** (⌘R): a thin strip under the ruler marks parts that are heavy to play (amber) and parts already rendered (green). Render a selection, a loop or the whole timeline, and those parts play smoothly. On phones with less memory this happens by itself while the editor is idle and the phone is charging. Rendered previews are never part of an export.
- **Background tasks** (in the project options) shows proxies, reversed clips, freeze frames, waveforms, captions and downloads in progress.

## 12. Export

1. Tap **Export**.
2. Pick a **preset**: YouTube, YouTube 4K, Shorts, Reels, Instagram Feed, TikTok, or Custom for the project's own size. If the preset's shape differs from the project's, Danaview offers to change the project.
3. **Custom settings** (tap Edit): format (MP4, or MOV on iPhone and iPad), codec, resolution, frame rate (Match project, 24, 25, 30, 48, 50 or 60), quality and bitrate. Only what your device can do is offered.
4. **Captions:** choose which caption tracks to burn in, and whether to also save them as SRT or VTT files.
5. **Save to:** Photos (iPhone, iPad) or Gallery (Android), **Files…**, or **Share…**. **Keep a copy in Danaview** also keeps one you can play from On This Device.
6. **Export.** You can't edit while it runs; you can cancel.

On Android the export keeps going if you leave the app, with a progress notification you can cancel from. On iPhone and iPad it pauses when you leave and picks up where it stopped when you come back. Exports are always new files; your originals are never changed.

## 13. Settings and storage

- **Settings › Video editor:** proxy media, default preview quality, render preview (Auto or Manual), center playhead on touch, snapping haptics, default format for new projects, and the Auto captions model (status, delete).
- **Settings › Storage & history:** "Video editor projects" (opens Projects), "Editor cache" (clears thumbnails, waveforms, proxies and rendered previews; projects are kept), and "Speech model" (deletes the Auto captions download).
- On Android, editor projects are not part of device backups.

## 14. Keyboard shortcuts

Work with any hardware keyboard on iPad and Android tablets (and phones). **⌘** is Command on iPad and Ctrl on Android. Press **⌘/** or **?** in the editor for this list. Shortcuts don't fire while you're typing in a text box, except Save and Esc.

| Keys | Action |
|---|---|
| Space or K | Play / pause |
| ← / → | Previous / next frame |
| Shift+← / Shift+→ | Back / forward 1 second |
| ↑ / ↓ | Previous / next edit point or marker |
| Home / End | Go to start / end |
| F | Fullscreen preview |
| S | Split at the playhead |
| Delete or Backspace | Delete |
| Shift+Delete or Shift+Backspace | Ripple delete |
| ⌘Z | Undo |
| ⌘⇧Z (Ctrl+Y on Android too) | Redo |
| ⌘S | Save (works in text boxes) |
| ⌘C / ⌘X / ⌘V | Copy / cut / paste |
| ⌘D | Duplicate |
| ⌘A | Select all |
| Esc | Cancel, then close the panel, then clear the selection, then leave fullscreen |
| M | Add marker |
| N | Snapping on / off |
| R | Ripple editing on / off |
| ⌘R | Render preview |
| ⌘= / ⌘− | Zoom in / out |
| Shift+Z | Zoom to fit |
| ⌘/ or ? | Show shortcuts |

In the player, **E** opens the current video in the editor.

## 15. Privacy

Everything you edit stays on your device. Danaview has no account, no ads and no tracking. The only time the editor uses the internet is the optional Auto captions download, and only after you agree; the request contains only the file's name. The microphone is used only while you record a voiceover. When you add from your photo library, Danaview sees only what you pick, and saving to Photos or Gallery only adds your export. The full policy is in Settings › About › Privacy Policy.
