import ../core/model
import ../core/restore_state
import ../core/shell_state
import ../state/dod_restore_state
import ../state/dod_snapshot
import ../types/dod_model
import ../types/dod_shadow_health

type
  ProjectionReadSource* = enum
    LegacyProjectionSource
    DodProjectionSource

proc projectionReadSource*(
    shadowHealth: DodShadowHealth): ProjectionReadSource =
  if shadowHealth.initialized and shadowHealth.readHealthy:
    DodProjectionSource
  else:
    LegacyProjectionSource

proc readProjectionSnapshot*(
    legacyModel: Model; shadow: DodModel;
    source: ProjectionReadSource): ShellSnapshot =
  case source
  of LegacyProjectionSource:
    shellSnapshot(legacyModel)
  of DodProjectionSource:
    dodShellSnapshot(shadow)

proc readProjectionLiveRestoreJson*(
    legacyModel: Model; shadow: DodModel;
    source: ProjectionReadSource): string =
  case source
  of LegacyProjectionSource:
    liveRestoreJson(legacyModel)
  of DodProjectionSource:
    dodLiveRestoreJson(shadow)

proc writeProjectionLiveRestoreState*(
    legacyModel: Model; shadow: DodModel; source: ProjectionReadSource;
    path = defaultLiveRestorePath()): LiveRestoreWriteResult =
  case source
  of LegacyProjectionSource:
    writeLiveRestoreState(legacyModel, path)
  of DodProjectionSource:
    writeDodLiveRestoreState(shadow, path)
