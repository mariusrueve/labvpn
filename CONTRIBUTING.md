# Contributing

Thanks for helping. labvpn is a small tool maintained in spare time, so small, focused
changes are easiest to accept.

1. Open an issue first for anything bigger than a fix.
2. Read [AGENTS.md](AGENTS.md). It's written for coding agents, and it's also the
   shortest guide for people: commands, code map and the safety rules.
3. Run `scripts/test.sh`.
4. In your pull request, say what you tested on real hardware. See
   [docs/testing.md](docs/testing.md).

To run your own build you need your own Developer ID, because the helper only accepts
signed clients. Change the Team ID in `Sources/LabVPNCore/HelperProtocol.swift`,
`Resources/install-helper.sh` and `scripts/release.sh`.

Share a gateway setup with others by adding a `.labvpn` file to `examples/`, if your
institution is happy for its settings to be public.
