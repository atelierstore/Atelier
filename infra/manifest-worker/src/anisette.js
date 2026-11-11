// The anisette servers Atelier signs in to Apple through, for free Apple ID
// signing (#49), and the client info it sends Apple in place of theirs.
// Apple's sign-in wants anisette data, which vouches for the device signing
// in, and which servers manage that changes with Apple's own changes: iloader
// needed four fixes between 13 and 28 October 2026. So Atelier asks here
// before each sign-in, and editing this list and deploying the Worker is
// enough to follow Apple, with no Atelier update. Atelier has a copy built
// in for when the Worker can't be reached,
// Packages/AtelierKit/Sources/AppleIDKit/anisette.json, which
// test/anisette.test.js keeps the same as this one.
//
// - servers: iloader's, in its order (2.4.1, 28 Oct 2026), its default
//   first. Then SideStore's public list (servers.sidestore.io/servers.json,
//   2 Nov 2026), HTTPS only, in its order. kind is what SideStore's list
//   says the server runs Apple's code on: "mac", "windows" or "other"; the
//   two only iloader lists have none.
// - tries: the most servers one sign-in tries, starting with the one that
//   worked last.
// - clientInfo: iloader's override while the servers catch up with Apple
//   (2.4.1). Without it, Atelier sends what each server says.
// - version: the format. A change older Ateliers can't read goes to a new
//   address, so they keep this one.
//
// Nothing is stored or logged; the request carries nothing.

export const ANISETTE_LIST = {
  version: 1,
  updated: "2026-11-02",
  tries: 4,
  clientInfo: {
    clientInfo: "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
    userAgent: "akd/1.0 CFNetwork/811.5.4",
  },
  servers: [
    { url: "https://mac-ani.jkcoxson.com", name: "jkcoxson (Mac)", kind: "mac" },
    { url: "https://ani.iloader.app", name: "iloader" },
    { url: "https://new.ani.sidestore.io", name: "SideStore (New)", kind: "mac" },
    { url: "https://ani3.stikstore.app", name: "StikStore" },
    { url: "https://ani.sidestore.io", name: "SideStore", kind: "other" },
    { url: "https://ani.sidestore.app", name: "SideStore (.app)", kind: "other" },
    { url: "https://ani.sidestore.zip", name: "SideStore (.zip)", kind: "other" },
    { url: "https://ani.846969.xyz", name: "SideStore (.xyz)", kind: "other" },
    { url: "https://ani.jkcoxson.com", name: "jkcoxson (Windows ADI)", kind: "windows" },
    { url: "https://win.ani.sidestore.io", name: "SideStore (Windows ADI)", kind: "windows" },
    { url: "https://ani.npeg.us", name: "nythepegasus", kind: "other" },
    { url: "https://anisette.wedotstud.io", name: "WE. Studio", kind: "other" },
    { url: "https://ani.xu30.top", name: "SteX", kind: "other" },
    { url: "https://ani.owoellen.rocks", name: "owoellen", kind: "other" },
    { url: "https://ani.idevicehacked.com", name: "iDH Server", kind: "other" },
    { url: "https://ani.neoarz.com", name: "neoarz", kind: "other" },
    { url: "https://ani3server.fly.dev", name: "pythonplayer123", kind: "other" },
    { url: "https://ani.jaydenha.uk", name: "Jayden's Server", kind: "other" },
    { url: "https://anisette.crystall1ne.dev", name: "crystall1nedev's server", kind: "other" },
    { url: "https://omni.ethxn.xyz", name: "ethxn's omnisette server", kind: "other" },
    { url: "https://ani.sjwon0368.dpdns.org", name: "koremi", kind: "other" },
    { url: "https://ani.uwucloud.fun", name: "uwucloud", kind: "other" },
    { url: "https://anisette.lillq.me", name: "Lill q", kind: "mac" },
  ],
};

export function anisette(request) {
  return new Response(request.method === "HEAD" ? null : JSON.stringify(ANISETTE_LIST), {
    status: 200,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
