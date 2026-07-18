# LoopKit Routing

LoopKit captures local audio sources and combines them into independently routable mixes for local listening and remote broadcast.

## Language

**Source**:
An independently controlled audio lane identified by a stable source ID, such as a captured application or microphone.
_Avoid_: Input, channel, node

**Destination**:
One of LoopKit's fixed mix endpoints: Monitor or Broadcast.
_Avoid_: Sink, output device

**Route**:
A directed connection that includes one Source in one Destination mix. A Route is either present or absent and has no independent gain.
_Avoid_: Cable, send, link

**Routing graph**:
The complete set of Routes applied atomically by the daemon and persisted with a Scene.
_Avoid_: Patchbay state, route list

**Monitor**:
The Destination heard locally through the selected physical output device.
_Avoid_: Headphones, speakers, cue

**Broadcast**:
The Destination delivered to a remote-call or streaming application through the configured virtual audio adapter.
_Avoid_: Discord, BlackHole, stream output

**Scene**:
A named snapshot of source controls, the Routing graph, master gain, capture selection, and Monitor preference.
_Avoid_: Preset, profile
