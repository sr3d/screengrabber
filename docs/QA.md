# Manual QA checklist

Run before each release. Each feature adds its steps here.

## Capture Text (⇧⌘2)

1. Press **⇧⌘2** in any app. The crosshair appears.
2. Drag over a paragraph of text in Safari. A toast reads `Copied: <first line>`
   with a `(+N more lines)` count. ⌘V into TextEdit pastes the text in reading order.
3. Repeat from the menu-bar icon ▸ **Capture Text**. Same result.
4. Drag over an area with no text (a photo or empty desktop). The toast reads
   `No text found` and the clipboard is unchanged.
5. Press **Esc** during the selection. Nothing happens, and the clipboard is unchanged.
6. Press ⇧⌘2 again while a selection is already showing. A second crosshair doesn't
   stack up.
7. Text Capture doesn't open the editor, doesn't save a file to the screenshot
   folder, and doesn't add to **Recent Screenshots**.
8. Multi-column text (a two-column page) or a non-English language (e.g. a Japanese
   or French web page) comes out in sensible order and language.
9. **⇧⌘4** still captures a screenshot and opens the editor as before.

## Autostamp (9)

1. Open the editor and press **9** (or click the circled-1 tool). Click three spots.
   Stamps **1**, **2**, **3** appear in the current color, and the tool stays on
   Autostamp (it doesn't jump to Select).
2. Hold the mouse button on a new click and drag. The stamp follows until release.
3. Change the color and the `Aa` size between clicks. Only the next stamp picks up
   the change; earlier stamps keep theirs.
4. Pick a white or yellow color. The number turns black so it stays readable.
5. Press **1** (Select), click stamp **2**, press **Delete**. Stamp 3 renumbers to
   **2**. **⌘Z** brings the deleted one back and the numbers return to 1, 2, 3.
6. In Select mode, drag a stamp to move it; change its color or `Aa` size while
   selected and it updates. It shows a dashed box but no resize handles.
7. Stamp past **9**. Two-digit numbers stay inside the circle.
8. Crop the image. Stamps stay on the same spot of the picture.
9. **Copy** / **Save…** — the exported PNG shows the stamps crisply at full size.
