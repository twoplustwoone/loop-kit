## Useful references
- [BlackHole](https://existential.audio/blackhole/) (external macOS loopback driver; not redistributed by LoopKit).
- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) (embedded helper registration and repair).
- ProxyAudioDevice (minimal HAL plug-in that forwards to another device).
- libASPL (library to simplify Audio Server Plug-ins).
- Roc VAD (driver + controller split on top of libASPL).

## Local docs
- `docs/ARCHITECTURE.md`: current v1 architecture and data contracts.
- `docs/MANUAL_TEST_PLAN.md`: Discord-focused validation checklist.
- `docs/DECISIONS.md`: BlackHole, helper, and Routing Graph decisions.
