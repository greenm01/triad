# Internal Engineering Trackers

**Note to End Users:** The documents in this directory are **internal engineering specifications and tracking matrices**. They are used by developers to track architectural divergence, gap analysis, and historical design decisions relative to other window managers (like Niri and Mango) during Triad's development.

For the official, user-facing documentation on how to configure and use Triad, please consult [`../configuration.md`](../configuration.md).

## Contents

- `config-command-matrix.md`: Tracks Triad's implementation status of various configuration keys and commands against Mango and River.
- `niri-overview-comp.md`: Audits Triad's overview mode behavior against a specific Niri commit, tracking compliance and known gaps.
- `niri-recent-windows-comp.md`: Tracks compliance of Triad's Most Recently Used (MRU) switcher against Niri's spec.
- `window-rules.md`: Details the architectural reasoning behind Triad's hybrid window rule model and triages remaining implementation work.
