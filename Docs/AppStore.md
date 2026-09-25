# App Store integration

iCordis can be embedded in an App Store application. Packaging an SDK does not certify its host application's behavior or guarantee review approval.

The core products use precompiled Swift, typed service registration and public Apple frameworks. Runtime `mount` activates an implementation already present in the signed app. The package includes no native code downloader, npm installer, shell, process-plugin runtime, or UI automation implementation.

Applications choose which provider plugins to ship. Keep local script execution, process plugins and broad desktop automation outside a store build's target dependencies. Remote model or tool services still need the host's appropriate data permissions and reviewable behavior. A remote bridge is not an exemption from software-hosting rules.

Hosts are responsible for:

- App Sandbox and entitlements, including user-selected file access on macOS.
- Public-API use, permissions for protected resources, and meaningful authorization before external actions.
- Disclosure and permission before sharing personal data with third-party AI.
- Background task limits, cancellation, and persistence/resumption instead of assuming an always-running iOS agent.
- Privacy manifests and required-reason API declarations where applicable to the final app and its dependencies.
- Additional requirements if offering third-party software, plugin marketplaces, or downloadable code.

Relevant Apple references (reviewed September 2026): [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), especially 2.4.5, 2.5.2, 2.5.4, 4.7, and 5.1.2; [App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox).

The extraction does not enable William's macOS App Sandbox or certify its existing desktop features for the Mac App Store. Those changes require a host-level distribution project.
