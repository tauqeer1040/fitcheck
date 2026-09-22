fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Android

### android metadata

```sh
[bundle exec] fastlane android metadata
```

Upload store listing metadata (text + graphics) to the Play Console internal draft

### android deploy

```sh
[bundle exec] fastlane android deploy
```

Upload the prebuilt release AAB + metadata + graphics to the Play Console internal draft

### android prod

```sh
[bundle exec] fastlane android prod
```

Build the release AAB and ship it to the Play production track (full rollout)

### android prod_staged

```sh
[bundle exec] fastlane android prod_staged
```

Build the release AAB and ship it to the Play production track as a staged rollout (default 20%)

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
