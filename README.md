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

Every edit, page selection, review mark and view toggle is saved automatically. Close or quit and reopen to resume. Imported originals are copied into `~/Library/Application Support/Scan Cleaner/Originals`; progress is in `library.json` beside it. Back up the whole Scan Cleaner folder to preserve your library. The original files you selected are never modified. Undo history is session-only.

Shadow reduction lightens illumination near the selected side edge. Very faint page boundaries still need a manual crop. Automatic text straightening searches roughly ±6 degrees, with manual fine rotation available up to ±12 degrees plus 90-degree turns.

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

After marking every page done, choose **PDF Export…**. For an illustrated book, start with **Illustrated**. Adaptive compression stores smooth letter edges in a full-page, 16-shade layer over the scanned colors and illustrations. It uses a whole-page JPEG when separation is unsuitable or would increase the file size. Use **Whole-page JPEG** or **Whole-page JPEG 2000** to preserve subtle shading throughout a page.

In Adaptive mode, **Simplification** levels 1–5 keep lettering over a photographic background. **Picture resolution** can go down to 10% and **Picture quality** to 5%. For smaller files, try levels 6–10. These reduce the foreground palette to 16, 8, 4, 2, or 1 ink color respectively. Level 10 also retains bright lettering over dark photographs and detects a palette of measured source ink colors for headings and flat graphics. For further control, turn on **Apply palette to pictures too** to use up to 32, 16, 8, 4, or 2 colors across the whole page. Both options keep the selected export resolution. Picture sliders apply only when the page has a photographic layer. Leave **Keep saved PDF within size target** off to export exactly the settings you preview. Zoom in on small captions, colored lettering, and shaded pictures as you adjust the slider.

**Smaller file** keeps a 300 dpi export setting for text and reduces the resolution and quality of pictures. Adaptive compression keeps grayscale source files in grayscale alongside color pages. **Read resolution from each scan** uses embedded scan resolution, with a manual fallback for untagged images. Existing saved PDF settings keep their original JPEG and manual-resolution behavior until you change them.

Use the page preview to check small print, faint marks, and illustrations, and compare image sizes across several pages. The size estimate samples up to five pages. If it exceeds your target, **Tune pictures for this target** tries several picture settings while keeping the selected text resolution. A 100 MB target for 300 pages allows about 333 KB per page on average. Enable **Keep saved PDF within size target** for a byte-limited export. The exporter measures the remaining space after every page and fits oversized pages using palette compression when Simplification is enabled. It first reduces photographic detail, then tries whole-page palettes with 32 and 16 colors, then reduces pixels if necessary. Other modes fit oversized pages using JPEG. It recognizes text before fitting the visible image. The final size appears after saving.

Local searchable-text OCR, ISBN lookup, and manual book details are available for every compression mode. **Back to Editing** preserves progress and settings. Source metadata is discarded and only supplied book information is added. **Save PDF…** creates a fresh PDF in page-list order.

### Native macOS appearance

The workspace uses a resizable navigation sidebar and a collapsible Adjustments inspector. On macOS 26 and later, primary actions and the zoom capsule use native Liquid Glass. macOS 14–15 use standard bordered actions and system materials. The viewer follows light and dark appearance, and the zoom capsule uses an opaque surface when Reduce Transparency is enabled. Use the toolbar’s Adjustments button to show or hide the inspector; Return or ⌘Return marks the current page done and advances.

The toolbar, sidebars, and bottom controls share one continuous AppKit sidebar-material backdrop with within-window blending. Its scan image follows the viewer’s zoom and pan in window coordinates, so panels never independently fit or crop their blur source. Reduce Transparency replaces it with the semantic window background. Colors follow the system appearance, including Dark Mode. There is no persistent bottom status bar; active processing and line-straightening instructions appear in the toolbar.

The app icon is authored in `Assets/AppIcon.icon` and compiled with Xcode’s asset compiler for native Liquid Glass rendering, with an ICNS fallback for older macOS versions. The build requires Xcode 26 or later. Existing libraries are automatically moved to the `Scan Cleaner` support folder on first launch.
