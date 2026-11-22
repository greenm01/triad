import std/osproc

const InheritedProcessOptions* = {poUsePath, poParentStreams}
const DetachedProcessOptions* = InheritedProcessOptions + {poDaemon}
