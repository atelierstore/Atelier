# Third-party notices

Atelier is licensed under the GNU General Public License v3.0 only (`GPL-3.0-only`); see [LICENSE](LICENSE).

It uses, or plans to reuse code from, the projects below. Keep this list in sync with what is actually in the repository: add a row when a dependency or copied code lands, and remove it if it goes away.

| Project | Used for | License | Copyright |
|---|---|---|---|
| [Feather](https://github.com/khcrysalis/Feather) | Code reused for the localhost install server, entitlement handling, idevice install flow and source parsing | GPL-3.0 | khcrysalis (samara) and Feather contributors; the install server was originally written by Lakr Aream |
| [zsign](https://github.com/zhlynn/zsign) | On-device IPA signing | MIT | zhlynn |
| [Zsign-Package](https://github.com/khcrysalis/Zsign-Package) | Swift package wrapping zsign, the one Feather builds; SigningKit depends on our fork ([atelierstore/Zsign-Package](https://github.com/atelierstore/Zsign-Package), `atelier` branch), which keeps the provisioning profile in signed apps and lists every code directory hash in the signature | MIT | zhlynn, khcrysalis |
| [OpenSSL](https://github.com/krzyzanowskim/OpenSSL) | Cryptography for zsign; comes in with Zsign-Package and ships in the app as OpenSSL.framework | Apache-2.0 (OpenSSL 3) | The OpenSSL Project Authors; packaged by Marcin Krzyżanowski |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | Unpacking and repacking IPAs for signing | MIT | Thomas Zoechling |
| [idevice](https://github.com/jkcoxson/idevice) | Talking to AFC and installd for the pairing-file install route, and pairing the iPhone on the phone itself (built from source, `Packages/IDeviceBridge`) | MIT | Jackson Coxson |
| [jktcp](https://github.com/jkcoxson/jktcp) | idevice's TCP stack for the tunnel to the iPhone, built from source with Atelier's change to how it receives (`Packages/IDeviceBridge/src/jktcp-receive-window.patch`) | MIT | Jackson Coxson |
| [IDeviceKit](https://github.com/khcrysalis/IDeviceKit) | Swift wrapper for idevice | MIT | khcrysalis |
| [isideload](https://github.com/nab138/isideload) | Signing in with an Apple ID and asking Apple's developer services for certificates, App IDs and provisioning profiles, for free Apple ID signing (built from source with idevice, `Packages/IDeviceBridge`) | MIT | nab138 (Nicholas Sharp) |
| [apple-codesign-quick](https://github.com/Dadoum/apple-crates) | Comes in with isideload, which signs apps with it; Atelier signs with zsign | LGPL-2.1-or-later | Dadoum |
| [Octicons](https://github.com/primer/octicons) | The GitHub mark on sources that are GitHub repos. GitHub and its logo are trademarks of GitHub, Inc. | MIT | GitHub Inc. |

## Rules for reused code

- A file copied or adapted from Feather keeps its original copyright header, and gets a line saying it was modified for Atelier.
- MIT dependencies come in through Swift Package Manager where possible, so their license files ship with them. Their notices must also appear on the in-app Acknowledgements screen.
- The app ships this file and shows its table on Settings › Acknowledgements, so keep the table's columns as they are. Each row's license text goes in `licenses/<Project>.txt`, named as in the Project column, or, for a GPL-3.0 project, comes from [LICENSE](LICENSE). A package test (`ThirdPartyNoticesTests`) fails when a row has no license text.
