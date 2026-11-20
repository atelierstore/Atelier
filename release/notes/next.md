## New

- The website installs Atelier with your Apple ID, free or paid, from the iPhone alone on iOS 27: Get Atelier's With your Apple ID opens a page whose Install Atelier button adds and runs a Shortcut, which starts the installer in rootshell, a free app, and opens the installer's own page in Safari, with nothing to type in rootshell. With LocalDevVPN, it pairs the iPhone, signs Atelier and installs it, and Atelier opens signed in. The line to copy into rootshell is still there, without the Shortcut. On an iPhone with an older iOS, Get Atelier lists the signing service first and the page says the installer needs iOS 27 (#22, #29, #30, #31, #32, #33).

## Fixes

- After the iPhone-only installer, Atelier's first launch shows its welcome, then Get Ready with the Apple ID already in, and no longer You're Signed In over the welcome. The sheet still opens when the sign-in needs you, or to offer Use for Installs while another certificate is in use (#28).
- When Apple still won't make Atelier's certificate after a revoke, Revoke Another? now says the certificate you picked is revoked, that sometimes you have to wait a while, and asks whether to revoke another one instead. It used to name the revoked certificate, which read wrong when the list showed another with the same name. The list says to pick one, and its rows are no longer blue like links (#40).
- When Apple's own sign-in or developer servers fail, signing in now says so: Apple's sign-in isn't working right now, so it isn't your password or your connection, rather than asking you to check your connection. It links to Apple's System Status, VoiceOver reads it, and Atelier stops instead of trying more sign-in servers, each of which would be one more sign-in on the Apple ID. A sign-in or step that Apple doesn't answer ends after a minute and says Apple didn't answer in time (#42, #44).

## Behind the scenes
