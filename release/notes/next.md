## New

- The website's Apple ID page takes rootshell from the App Store again, instead of its beta on TestFlight: the App Store's rootshell 1.0.16 has what the installer and its Shortcut need (#52).

## Fixes

- Signing in with a free Apple ID works again. Since 20 Nov 2026, Apple has refused sign-ins that call the Mac "macOS", as Atelier's did, which ended with "Apple's sign-in isn't working right now" or "check your connection". Atelier now says "Mac OS X", as Apple's own Macs do, and makes a new sign-in machine when that changes, so Apple may ask for a code once more (#53).

## Behind the scenes
