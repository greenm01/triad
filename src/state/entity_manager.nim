import std/[options, tables]
import ../types/core

proc len*[ID, T](manager: EntityManager[ID, T]): int =
  manager.data.len

proc contains*[ID, T](manager: EntityManager[ID, T]; id: ID): bool =
  manager.index.hasKey(id)

proc entity*[ID, T](manager: EntityManager[ID, T]; id: ID): Option[T] =
  if not manager.index.hasKey(id):
    return none(T)
  some(manager.data[manager.index[id]])

proc mEntity*[ID, T](manager: var EntityManager[ID, T]; id: ID): var T =
  manager.data[manager.index[id]]

proc insert*[ID, T](manager: var EntityManager[ID, T]; entity: T) =
  let id = entity.id
  if manager.index.hasKey(id):
    raise newException(ValueError, "entity already exists: " & $id)
  manager.index[id] = manager.data.len
  manager.data.add(entity)

proc delete*[ID, T](manager: var EntityManager[ID, T]; id: ID): bool =
  if not manager.index.hasKey(id):
    return false

  let removeAt = manager.index[id]
  let lastAt = manager.data.high
  if removeAt != lastAt:
    manager.data[removeAt] = manager.data[lastAt]
    manager.index[manager.data[removeAt].id] = removeAt

  manager.data.setLen(lastAt)
  manager.index.del(id)
  true

iterator entities*[ID, T](manager: EntityManager[ID, T]): T =
  for entity in manager.data:
    yield entity

proc hasDenseIndex*[ID, T](manager: EntityManager[ID, T]): bool =
  if manager.index.len != manager.data.len:
    return false
  for idx, entity in manager.data:
    if not manager.index.hasKey(entity.id):
      return false
    if manager.index[entity.id] != idx:
      return false
  true
