## New

- The website installs Atelier with your certificate from a computer too: it signs Atelier there and shows a QR code, which opens iOS's install alert on your iPhone (#11).

## Fixes

- When a source's GitHub repo doesn't have the branch or file the source points to, Atelier says which is missing, instead of saying your GitHub account can't see the repo. For a public repo, it no longer asks you to sign in (#13).

## Behind the scenes

- Each signed build's record has an install link that opens iOS's install alert from Safari (#10).
- Pull requests add their lines to the next release's notes as they're merged, and its build checks they did (#12).
