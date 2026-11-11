// The certificate page's signer, off the page's thread (certificate.js
// starts it): zsign in WebAssembly opens the .p12 for the checks and signs
// Atelier (signer.js). The page ends the worker after each signing, which
// frees the memory it took. zsign's log is kept for the console when
// something fails.
//
//   {type: "load"}                                 → nothing: zsign loads, for the checks to come
//   {id, type: "open", p12, password}              → {id, result: {status, certificate?}}
//   {id, type: "sign", ipa, p12, profile, password,
//        packagedCertificate}                      → {id, result: {ipa}}
//   anything that fails                            → {id, error: {reason, message, detail}}

import { SignError, openP12, signIPA } from "./signer.js";
import createSigner from "./zsign.js";

let log = [];
let module;
// A module that couldn't load is loaded again for the next message.
const signer = () => (module ??= createSigner({ print: (line) => log.push(line), printErr: (line) => log.push(line) }).catch((error) => {
  module = undefined;
  throw error;
}));

self.onmessage = async ({ data: { id, type, ...input } }) => {
  log = [];
  try {
    const zsign = await signer();
    if (type === "load") return;
    if (type === "open") {
      const result = openP12(zsign, input.p12, input.password);
      self.postMessage({ id, result }, result.certificate ? [result.certificate.buffer] : []);
    } else if (type === "sign") {
      const ipa = await signIPA(zsign, input);
      self.postMessage({ id, result: { ipa } }, [ipa.buffer]);
    }
  } catch (error) {
    // WebAssembly that runs out of memory aborts, and takes the module
    // with it; the page starts a new worker for anything after.
    const known = error instanceof SignError;
    const memory = !known && /memory|OOM/i.test(String(error?.message ?? error));
    self.postMessage({
      id,
      error: {
        reason: known ? error.reason : "signingFailed",
        message: known ? error.message : memory ? "Atelier couldn't be signed: Safari ran out of memory. Close other tabs and try again." : "Atelier couldn't be signed. Try again.",
        detail: [known ? error.detail : String(error?.stack ?? error), ...log.slice(-20)].join("\n"),
      },
    });
  }
};
