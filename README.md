# Scan Tidy

A native, offline Mac app for preparing book scans for a PDF. Requires macOS 14 or later. The included app is built for Apple silicon.

## Open the app

Double-click **Scan Tidy.app** in this folder. You can also drag it into Applications. Your library lives separately from the app, so moving the app does not move or erase your work.

## Work through a book

1. Click **Import Scans** and select your images. They are added in natural filename order (2 before 10). PNG, JPEG, TIFF, HEIC and BMP are supported. Import individual page images; a multi-page TIFF imports its first frame only.
2. Click **Suggest Crop & Angle**. Clear page boundaries can provide both; pale borders fall back to text-based straightening. Review every suggestion. **Straighten All Pages** estimates a separate text angle for each image, keeping existing crop and shadow settings.
3. Click **Auto Detect Page Edges** to crop without changing rotation. It checks all four borders across multiple scan lines, allows slanted edges, rejects thin printed rules, and prefers the current page edge inside visible sheets beyond it. Borders without reliable evidence stay at the image boundary; if none are detected, the current crop stays unchanged. Review the suggestion, especially on faint or curved edges. You can also drag the blue crop edges and fine-tune each edge with its slider. The **Reset** button at the top right of the inspector clears the current page's crop, rotation, and shadow adjustments; Command-Z undoes the reset. Double-click any slider to reset it individually: crop and angle to zero, shadow width to 25%, and shadow strength to 65%. Shadow slider changes follow the same saved-default behavior as normal adjustments.
4. Turn on **Spine shadow** (off initially), choose **Left** or **Right**, and adjust **Width** and **Strength**. Width is a percentage of the full scan, fading inward from the selected edge. Switching off preserves the chosen side, width and strength for later use. Side, width, and strength changes become the saved defaults for untouched pages, including newly imported scans. Each page keeps its own Spine shadow checkbox state; new scans start with it off. Any page you have cropped, straightened, adjusted, or marked done keeps its own settings when defaults change. Use **Original** to compare and **Crop preview** to see the exported framing.
5. Click **Done & Next** (Command-Return). Previous/next shortcuts are Command-Left and Command-Right. Command-Z undoes page edits in the current session.
6. Use **Copy**, then **Paste**, or apply copied settings to all or matching odd/even pages. This is useful for the alternating edges of a book. Review batch results; batch edits clear their done marks.
7. Click **Export Images**. Every page is exported in list order as a numbered, full-resolution PNG, inside a new dated folder. The files are ready to combine into a PDF using your preferred tool.

Drag pages up or down in the sidebar to rearrange them. The order is saved automatically and used for navigation, odd/even settings, and export numbering. Each page keeps its edits and done mark. Sidebar thumbnails show each page's current crop and rotation. Reopening the app scrolls the sidebar to your last selected page. Switching pages preserves the sidebar's scroll position when the new selection is visible; an offscreen selection scrolls just enough to come into view. You can scroll away from the selection freely until you switch pages again.

Drag the blue crop edges or corner handles directly to resize an existing crop. The opposite edges stay fixed, and the crop stays within the scan. Dragging elsewhere on the page leaves the crop unchanged. Each completed drag is one undoable edit.

Use the viewer's **+ / − magnifying glass** buttons or pinch on a trackpad to zoom up to 600% of the fitted view. Scroll horizontally or vertically to inspect different parts of the enlarged page, and click **Fit** to see the whole page again. Zoom only changes the view; it does not change crop values or exported images. Selecting another page returns to Fit.

In **Straighten**, click **Draw Line to Straighten**, then click once at each end of a near-horizontal line of text. The first click places a dot and the second straightens the page. Clicks work in either direction. Press **Esc** or **Cancel Line** to leave without changing the page. This tool uses the existing ±12° fine-rotation range and preserves crop and shadow settings. The cyan grid also helps with manual straightening; angle buttons adjust by 0.05 degrees.

To remove a page, select it in the sidebar, click **Delete Page…**, and confirm. The next page is selected, or the previous page if you deleted the last one. Your original source file stays untouched, and you can import it again later.

Every edit, page selection, review mark and view toggle is saved automatically. Close or quit and reopen to resume. Imported originals are copied into `~/Library/Application Support/Scan Tidy/Originals`; progress is in `library.json` beside it. Back up the whole Scan Tidy folder to preserve your library. The original files you selected are never modified. Undo history is session-only.

Shadow reduction lightens illumination near the selected side edge; it does not reconstruct missing text or flatten curved text near the spine. Very faint page boundaries still need a manual crop. Automatic text straightening searches roughly ±6 degrees, with manual fine rotation available up to ±12 degrees plus 90-degree turns. This version exports images, not PDFs, and keeps one continuing library.

## Included samples

`TestScans` contains the two supplied scans. `TestResults` contains full-resolution cleaned examples and smaller previews. The cleaned examples use manually chosen crops, automatic text angles, and 65% shadow reduction. Files ending in `-auto-crop.png` show the page detector output without straightening or shadow correction.

## Build and verify

With Xcode installed:

```sh
./scripts/build.sh
swift test
```

The build produces a locally signed `Scan Tidy.app`. Tests cover crop bounds, restoration of saved selection/edits/review/view settings, correction of a known two-degree rotation, full-resolution exports of both supplied scans, and an offscreen app layout render.

Existing libraries remain compatible. Previously adjusted pages keep their original correction, including the old two-sided effect, until you change their shadow controls. New default settings are saved across app restarts.
