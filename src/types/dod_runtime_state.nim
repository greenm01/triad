import ../core/model
import dod_model
import dod_shadow_health

type
  TriadRuntimeState* = object
    legacyModel*: Model
    shadowModel*: DodModel
    shadowHealth*: DodShadowHealth
