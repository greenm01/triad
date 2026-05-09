import options
import entity_manager
import id_gen
import dod_iterators
import dod_queries
import dod_invariants
import dod_snapshot
import ../entities/dod_ops
import ../types/core
import ../types/dod_model
import ../types/shell_snapshot

export dod_iterators
export dod_queries
export dod_invariants
export dod_snapshot
export dod_ops
export core
export dod_model
export shell_snapshot
export id_gen

proc window*(model: DodModel; winId: WindowId): Option[WindowData] =
  model.windowData(winId)

proc tag*(model: DodModel; tagId: TagId): Option[TagData] =
  model.tagData(tagId)

proc column*(model: DodModel; columnId: ColumnId): Option[ColumnData] =
  model.columnData(columnId)

proc output*(model: DodModel; outputId: OutputId): Option[OutputData] =
  model.outputData(outputId)

proc hasWindow*(model: DodModel; winId: WindowId): bool =
  model.window(winId).isSome

proc hasTag*(model: DodModel; tagId: TagId): bool =
  model.tag(tagId).isSome

proc hasColumn*(model: DodModel; columnId: ColumnId): bool =
  model.column(columnId).isSome

proc hasOutput*(model: DodModel; outputId: OutputId): bool =
  model.output(outputId).isSome

proc windowsCount*(model: DodModel): int =
  model.windows.len

proc tagsCount*(model: DodModel): int =
  model.tags.len

proc columnsCount*(model: DodModel): int =
  model.columns.len

proc outputsCount*(model: DodModel): int =
  model.outputs.len
