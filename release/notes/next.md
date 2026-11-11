## New

- The website installs Atelier with your certificate from a computer too: it signs Atelier there and shows a QR code, which opens iOS's install alert on your iPhone (#11).
- The website's Get Atelier lists AltStore PAL as planned, and recommends it first to visitors in the EU, Japan and Brazil, where Apple allows it (#7).
- Apps signed with a certificate that comes with App Groups, as signing services' often do, keep theirs too: Atelier keeps each app's App Groups in a folder of its own in one of the certificate's, so its widgets and extensions see the app's data. Other apps signed with that certificate could read the folder. Custom Install › Advanced › Share App Groups turns it off for an app (#2).
- Atelier installed with a free Apple ID renews itself every week, and signs its own updates and Custom Install… with that Apple ID, once you sign in with it in Atelier. Until then, it's in the Library's Renew section with Sign In (#3).

## Fixes

## Behind the scenes

- Each signed build's record has an install link that opens iOS's install alert from Safari (#10).
- Pull requests add their lines to the next release's notes as they're merged, and its build checks they did (#12).
