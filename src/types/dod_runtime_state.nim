import ../core/model
import dod_model
import dod_shadow_health
import dod_runtime_policy

export dod_runtime_policy

type
  TriadRuntimeState* = object
    legacyModel*: Model
    shadowModel*: DodModel
    shadowHealth*: DodShadowHealth
    policy*: TriadRuntimePolicy
