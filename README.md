# gridify

Turn a photo into a print-ready PDF with a drawing grid on it, for the grid
method of copying an image by hand.

gridify crops an image to your print size (default 5×7 in), draws an inch grid
over it, centers it on a letter or A4 page and adds tick marks in the margin so
you can rule the same grid on your drawing paper. It is a single native macOS
binary with no Python or other dependencies.

## Install

Needs macOS with the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/tbaums/gridify.git
swiftc -O gridify/gridify.swift -o ~/.local/bin/gridify
```

Any directory on your `PATH` works in place of `~/.local/bin`.

## Use

```sh
gridify photo.jpg          # PDF goes to the iCloud Drive root
gridify --ui photo.jpg     # position the crop in a window first
gridify --ui               # open the window, then pick one or more images
```

In the `--ui` window:

- **Open…** (⌘O) adds one or more images. Switch between them with the file
  menu or ⌘[ / ⌘]. Each image keeps its own crop, zoom and rotation; cell
  size, page and labels apply to all of them.
- Drag (or use the arrow keys) to move the crop.
- Scroll, pinch or press `+`/`-` to zoom; **Fit** resets.
- Use the rotate buttons for 90° turns and the slider to straighten (±45°).
- Choose the cell size, page size and labels; **Save PDF** (Return or ⌘S)
  writes the current image's PDF and opens it in Preview. **Save All** (⌥⌘S)
  writes every open image and shows the PDFs in Finder.

Options:

| Option | Default | |
|---|---|---|
| `-o, --out PATH` | iCloud Drive/`<name>_grid.pdf` | output file |
| `--width IN`, `--height IN` | 5, 7 | print size, inches |
| `--cell IN` | 1 | grid cell size, inches |
| `--focus-x`, `--focus-y` | 0.5 | crop position, 0 = left/top, 1 = right/bottom |
| `--rotate DEG` | 0 | rotate clockwise before cropping |
| `--page letter\|a4` | letter | page size |
| `--labels` | off | label columns A… and rows 1… |

The output prints the effective resolution, and gridify warns when the photo is
below 180 px per inch at the chosen print size.

## Printing

Print at **Actual size / 100%**. "Fit to page" scales the image and the grid
stops matching your paper. Measure one printed cell with a ruler; if it is off,
fix the print dialog, not the PDF.

## License

MIT
