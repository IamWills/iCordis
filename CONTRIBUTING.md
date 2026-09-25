# Contributing

Open an issue to discuss API or architectural changes, or submit a focused pull request.

```sh
swift test
swift run icordis-demo
xcodebuild -scheme iCordisHTTP -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Use Swift tools 6.0 or newer on macOS. The first release uses Swift 5 language mode for compatibility with the extracted host. Add meaningful regression tests for behavior changes and an external-client test when adding public APIs. Tests should use deterministic providers and no paid model calls.

Keep iCordisKernel free of Agent/domain dependencies. Implement new capabilities as plugins, declare service dependencies, and attach teardown to PluginContext effects. Do not introduce application UI, embedded credentials, shell execution, or a heavyweight inference runtime into the default products.

Source compatibility matters even during 0.x development. Explain breaking changes, provider lifecycle behavior, and host migration in the PR. New contributions are distributed under the repository's MIT license.
