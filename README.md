# Scan Cleaner

A native, offline Mac app for preparing book scans for a PDF. Requires macOS 14 or later. The included app is built for Apple silicon.

## Open the app

Double-click **Scan Cleaner.app** in this folder. You can also drag it into Applications. Your library lives separately from the app, so moving the app does not move or erase your work.

## Work through a book

1. Click **Import Scans** and select your images. They are added in natural filename order (2 before 10). PNG, JPEG, TIFF, HEIC and BMP are supported. Import individual page images; a multi-page TIFF imports its first frame only.
2. Click **Straighten & Crop All Pages** (the wand button) to automatically straighten the text and detect page edges on every page. Existing shadow settings and 90-degree rotations are preserved. Pages with unclear edges keep their previous crop. Review each page afterward. One Command-Z or Control-Z undoes the entire run, restoring all affected pages and their previous done states. **Auto Straighten Page** adjusts only the current page’s angle.
3. Click **Auto Detect Page Edges** to crop without changing rotation. It looks for the current page's side edge inside visible sheets beyond it; review the suggestion, especially on faint or curved edges. You can also drag the blue crop edges and fine-tune each edge with its slider. The **Reset** button at the top right of the inspector clears the current page's crop, rotation, and shadow adjustments; Command-Z undoes the reset. Double-click any slider to reset it individually: crop and angle to zero, shadow width to 25%, and shadow strength to 65%. Shadow slider changes follow the same saved-default behavior as normal adjustments.
4. Turn on **Spine shadow** (off initially), choose **Left** or **Right**, and adjust **Width** and **Strength**. Width is a percentage of the full scan, fading inward from the selected edge. Switching off preserves the chosen side, width and strength for later use. Side, width, and strength changes become the saved defaults for untouched pages, including newly imported scans. Each page keeps its own Spine shadow checkbox state; new scans start with it off. Any page you have cropped, straightened, adjusted, or marked done keeps its own settings when defaults change. Use **Original** to compare and **Crop preview** to see the exported framing.
5. Click **Mark Done & Next** (Return or Command-Return). Previous/next shortcuts are Command-Left and Command-Right. Command-Z undoes page edits in the current session.
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

`TestScans` contains the two supplied scans. `TestResults` contains full-resolution cleaned examples and smaller previews. The cleaned examples use manually chosen crops, automatic text angles, and 65% shadow reduction.

## Build and verify

With Xcode installed:

```sh
./scripts/build.sh
swift test
```

The build produces a locally signed `Scan Cleaner.app`. Tests cover crop bounds, restoration of saved selection/edits/review/view settings, correction of a known two-degree rotation, full-resolution exports of both supplied scans, and an offscreen app layout render.

Existing libraries remain compatible. Previously adjusted pages keep their original correction, including the old two-sided effect, until you change their shadow controls. New default settings are saved across app restarts.

## PDF export

After marking every page done, choose **PDF Export…**. The export screen offers color/grayscale, scan and output resolution, JPEG quality, local searchable-text OCR, ISBN lookup, manual book details, and a sampled file-size estimate. **Back to Editing** preserves progress and settings. Source metadata is discarded and only supplied book information is added. **Save PDF…** creates a fresh PDF in page-list order; the final size appears after saving. See [PDF export research and limitations](EXPORT-NOTES.md) for upload-limit confidence, compression choices, and OCR behavior.

### Native macOS appearance

The workspace uses a resizable navigation sidebar and a collapsible Adjustments inspector. On macOS 26 and later, primary actions and the zoom capsule use native Liquid Glass. macOS 14–15 use standard bordered actions and system materials. The viewer follows light and dark appearance, and the zoom capsule uses an opaque surface when Reduce Transparency is enabled. Use the toolbar’s Adjustments button to show or hide the inspector; Return or ⌘Return marks the current page done and advances.

The toolbar, sidebars, and bottom controls share one continuous AppKit sidebar-material backdrop with within-window blending. Its scan image follows the viewer’s zoom and pan in window coordinates, so panels never independently fit or crop their blur source. Reduce Transparency replaces it with the semantic window background. Colors follow the system appearance, including Dark Mode. There is no persistent bottom status bar; active processing and line-straightening instructions appear in the toolbar.

The app icon is authored in `Assets/AppIcon.icon` and compiled with Xcode’s asset compiler for native Liquid Glass rendering, with an ICNS fallback for older macOS versions. The build requires Xcode 26 or later. The existing `Scan Tidy` library folder is retained across the rename.
