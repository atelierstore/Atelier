## New

- Atelier is in other apps' share sheets for links. Share a link to an .ipa, from a chat, Safari or any other app, and Atelier opens and asks to install it, as an install link does, then downloads, signs and installs it. A link to a source or a GitHub repo opens Add Source. Shared .ipa files keep installing straight away. If iOS won't let Atelier open from the share sheet, a sheet says so, with the link to copy (#56, #57).
- The website's Apple ID page takes rootshell from the App Store again, instead of its beta on TestFlight: the App Store's rootshell 1.0.16 has what the installer and its Shortcut need (#52).

## Fixes

- When Apple's own sign-in or developer servers fail, signing in now says so: Apple's sign-in isn't working right now, so it isn't your password or your connection, rather than asking you to check your connection. It links to Apple's System Status, VoiceOver reads it, and Atelier stops instead of trying more sign-in servers, each of which would be one more sign-in on the Apple ID. A sign-in or step that Apple doesn't answer ends after a minute and says Apple didn't answer in time (#42, #44).
- Signing in with a free Apple ID works again. Since 20 Nov 2026, Apple has refused sign-ins that call the Mac "macOS", as Atelier's did, which ended with "Apple's sign-in isn't working right now" or "check your connection". Atelier now says "Mac OS X", as Apple's own Macs do, and makes a new sign-in machine when that changes, so Apple may ask for a code once more (#53).
- An Apple ID that gets its codes by text message now gets one text when signing in, rather than two with different codes, the first of which no longer worked. Atelier asks for the code Apple texted first, as the iPhone-only installer does (#54, #55).

## Behind the scenes
