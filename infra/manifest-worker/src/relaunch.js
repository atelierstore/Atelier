// Atelier's install of itself (#24). iOS only installs over Atelier once
// it has closed, and doesn't open it again afterwards. So while Atelier is
// in front, it leaves a background download of /relaunch with iOS, which
// this answers `delay` seconds later; iOS then relaunches Atelier in the
// background, as the build it installed, to hand over the download's
// events, and that build says it was installed. iOS starts a download it's
// given at once, whereas it put off one timed with earliestBeginDate for
// over half a minute on the test iPhone (28 Oct 2026).
// Nothing is stored or logged; the request carries nothing but the delay.

export const MAX_DELAY = 60;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export async function relaunch(url, wait = sleep) {
  const delay = url.searchParams.get("delay");
  if (delay === null || !/^\d+$/.test(delay) || Number(delay) > MAX_DELAY) {
    return new Response(`delay must be a whole number of seconds up to ${MAX_DELAY}`, {
      status: 400,
      headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" },
    });
  }
  await wait(Number(delay) * 1000);
  return new Response(null, { status: 204, headers: { "Cache-Control": "no-store" } });
}
