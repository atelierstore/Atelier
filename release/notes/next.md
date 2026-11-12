## New

- The website installs Atelier with your certificate from a computer too: it signs Atelier there and shows a QR code, which opens iOS's install alert on your iPhone (#11).
- The website's Get Atelier lists AltStore PAL as planned, and recommends it first to visitors in the EU, Japan and Brazil, where Apple allows it (#7).
- The website counts visits and taps per day, with no cookies and nothing that identifies visitors, and shows them on a private Stats page. Its privacy answers now say what's counted (#19).
- Apps signed with a certificate that comes with App Groups, as signing services' often do, keep theirs too: Atelier keeps each app's App Groups in a folder of its own in one of the certificate's, so its widgets and extensions see the app's data. Other apps signed with that certificate could read the folder. Custom Install › Advanced › Share App Groups turns it off for an app (#2).
- Atelier installed with a free Apple ID renews itself every week, and signs its own updates and Custom Install… with that Apple ID, once you sign in with it in Atelier. Until then, it's in the Library's Renew section with Sign In (#3).
- After the iPhone-only installer, Atelier is signed in from the start: on first open it signs in by itself with the Apple ID the installer used, as the same device to Apple so it shouldn't ask for a code again, and reuses the installer's certificate instead of making a second one, since a free Apple ID only gets two. If Apple still asks for a code, or the sign-in fails, the Sign In sheet opens already filled in. When Apple still counts a certificate you just revoked, Atelier offers the remaining ones again as Revoke Another? instead of stopping, as revoking another frees a place where waiting doesn't (#17).
- Re-sign on an app installed with an Apple ID whose certificate Apple revoked or that ended gets that Apple ID a new certificate, signing in with the password in your Keychain, then signs the app again with it, even when another certificate is in use. The app is installed over, rather than deleted first, and keeps its data. The Apple ID's page has New Certificate too, so you don't sign out and in again (#21).
- Atelier keeps Apple's sign-in token for each Apple ID in the Keychain, and signs in again with it, without the password or a code, for installs, Check Now and the weekly renewals, until Apple ends it. Only then does it sign in with the password, as before, and keep that sign-in's token. A renewal in the background goes ahead with the token even after Apple asked for a code. Apple ID Log says how long Apple says each token lasts (#23).

## Fixes

- Settings says where its badge comes from: under Certificates, a line names the certificate or Apple ID that's revoked, expired or about to expire, and how many others there are, as in "side@alxp.gr is revoked, and 2 other issues". Before, Settings only named the certificate in use, so one revoked that wasn't in use showed nowhere (#26).
- When a source's GitHub repo doesn't have the branch or file the source points to, Atelier says which is missing, instead of saying your GitHub account can't see the repo. For a public repo, it no longer asks you to sign in (#13).
- An offloaded app stays in Offloaded while another app installs. Before, an install could take the install check the offloaded app still held, so the offloaded app briefly showed in Installed with "Data not put back" (#18).
- An app being re-signed shows once, in its own row in Re-sign, with its progress and the ring that stops it, rather than in Downloads too. It stays in Re-sign while it's deleted to be installed again. Reinstall and Custom Install… show in the app's row the same way. "Re-signed just now", "Updated just now" and "Renewed" stay on one line (#20).

## Behind the scenes

- Each signed build's record has an install link that opens iOS's install alert from Safari (#10).
- Pull requests add their lines to the next release's notes as they're merged, and its build checks they did (#12).
- The README is a front page for developers and sideloading enthusiasts: highlights, how the pipeline works, atelier-install, and up-to-date notes on the code, building and CI (#24).
