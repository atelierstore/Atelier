// The Copy buttons of the sideload page (sideload.js) and the Apple ID page
// (apple-id.js).

/** Copies `text()` when `button` is tapped, and says Copied. Where the
 *  clipboard refuses, it selects the text in `node()` instead, and says
 *  Selected. */
export function copies(button, text, node) {
  const label = button.textContent;
  let timer;
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(text());
      button.textContent = "Copied";
    } catch {
      const range = document.createRange();
      range.selectNodeContents(node());
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      button.textContent = "Selected";
    }
    clearTimeout(timer);
    timer = setTimeout(() => { button.textContent = label; }, 1800);
  });
}
