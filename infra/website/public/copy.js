// Copying on the sideload page (sideload.js) and the Apple ID page
// (apple-id.js).

/** Copies `text`, and says whether it could. Where the clipboard refuses,
 *  it selects the text in `node` instead, for the reader to copy. */
export async function copy(text, node) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    const range = document.createRange();
    range.selectNodeContents(node);
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    return false;
  }
}

/** Copies `text()` when `button` is tapped, and says Copied. Where the
 *  clipboard refuses, it selects the text in `node()` instead, and says
 *  Selected. */
export function copies(button, text, node) {
  const label = button.textContent;
  let timer;
  button.addEventListener("click", async () => {
    button.textContent = await copy(text(), node()) ? "Copied" : "Selected";
    clearTimeout(timer);
    timer = setTimeout(() => { button.textContent = label; }, 1800);
  });
}
