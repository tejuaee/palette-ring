# Palette Ring

A tiny macOS menu-bar app: select a photo in Finder, **hold Shift**, and its colour palette appears in a ring around your cursor. Move onto a colour and **release Shift**. The palette is saved to Downloads (`<photo> palette.png` + `<photo> palette.css`) and the colour you picked is copied as a hex code.

Release Shift while the cursor is still on the photo in the middle to cancel. Shift-clicking or moving the mouse right after pressing Shift counts as Finder multi-select, so the ring stays out of the way.

## Build & run

```sh
./build.sh
open "build/Palette Ring.app"
```

The first time it runs, macOS asks to let Palette Ring control Finder. Click **OK**, because that's how it reads which photo is selected. No Accessibility permission is needed.

## How it works

- Polls the Shift key state about 60 times a second, only while Finder is frontmost.
- Asks Finder for the current selection through AppleScript.
- Shrinks the photo to 96 px and runs k-means (k = 6) to find the dominant colours.
- Draws the ring in a transparent, click-through panel.

Headless check: `PaletteRing --preview <image> <outdir>` prints the hex codes and writes the palette files plus a ring preview image.
