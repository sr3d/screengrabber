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
