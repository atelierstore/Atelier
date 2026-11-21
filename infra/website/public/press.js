// Every page loads this. Safari on iOS only shows a pressed control's
// :active style, such as a button shrinking or a link dimming (site.css), on
// a page that listens for touches, and the page hides iOS's own grey box
// over what's tapped. This listens, and does nothing else.

document.addEventListener("touchstart", () => {}, { passive: true });
