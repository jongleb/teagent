# Changes

## Unreleased

- core: Parsing large config files is about twice as fast.
- api: New endpoint `/v2/health` reports the state of every backend.
- core: `Config.load_file` is gone; call `Config.load` with a path instead.
- cli: Fixed a crash when the config path contains spaces.

## core 2.4.1

- core: Fixed reading configs with a byte order mark.

## web 3.1.2

- web: The login page no longer flashes on slow networks.
