## New

- The website installs Atelier with your certificate from a computer too: it signs Atelier there and shows a QR code, which opens iOS's install alert on your iPhone (#11).
- The website's Get Atelier lists AltStore PAL as planned, and recommends it first to visitors in the EU, Japan and Brazil, where Apple allows it (#7).
- Apps signed with a certificate that comes with App Groups, as signing services' often do, keep theirs too: Atelier keeps each app's App Groups in a folder of its own in one of the certificate's, so its widgets and extensions see the app's data. Other apps signed with that certificate could read the folder. Custom Install › Advanced › Share App Groups turns it off for an app (#2).
- Atelier installed with a free Apple ID renews itself every week, and signs its own updates and Custom Install… with that Apple ID, once you sign in with it in Atelier. Until then, it's in the Library's Renew section with Sign In (#3).
- Find Open Spaces Automatically, in Settings › Home Screen › Open Spaces, goes to a page of your Home Screen for a moment, takes a screenshot and comes back, then marks the open spaces it saw there for you to check. It looks for each app's own icon, so a busy wallpaper or dark icons don't throw it off. The first time, it downloads Apple's developer disk image, which lets it press Home, go to the page and take the screenshot. iOS might then notify you that your iPhone was viewed remotely: that's normal (#16).
- Settings › Home Screen › Open Spaces goes from page to page with a swipe, as on your Home Screen (#16).

## Fixes

- When a source's GitHub repo doesn't have the branch or file the source points to, Atelier says which is missing, instead of saying your GitHub account can't see the repo. For a public repo, it no longer asks you to sign in (#13).

## Behind the scenes

- Each signed build's record has an install link that opens iOS's install alert from Safari (#10).
- Pull requests add their lines to the next release's notes as they're merged, and its build checks they did (#12).
- jktcp, the TCP stack of the tunnel to the iPhone, is built from source with a change to how it receives, so one lost segment no longer slows a long transfer to a crawl (#16).
