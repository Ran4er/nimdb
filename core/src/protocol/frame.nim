import std/[net, asyncnet, asyncdispatch]
import ../storage/types  # Подтягиваем LE-хелперы (leGet32, lePut64 и т.д.)

type
  Frame* = object
    opcode*: uint8
    flags*: uint8
    version*: uint8
    requestId*: uint64
    payload*: seq[byte]

const FrameHeaderSize = 15

# ─── Чистые функции для работы с байтами (без сети) ───────────────────────

proc encodeHeader*(f: Frame): array[FrameHeaderSize, byte] =
  ## Сериализует заголовок фрейма в 15 байт, вычисляя length на лету
  let length = uint32(f.payload.len)
  lePut32(result, 0, length)
  result[4] = f.opcode
  result[5] = f.flags
  result[6] = f.version
  lePut64(result, 7, f.requestId)

proc decodeHeader*(buf: openArray[byte]): tuple[length: uint32, opcode, flags, version: byte, requestId: uint64] =
  ## Десериализует заголовок фрейма из буфера
  result.length    = leGet32(buf, 0)
  result.opcode    = buf[4]
  result.flags     = buf[5]
  result.version   = buf[6]
  result.requestId = leGet64(buf, 7)


# ─── Сетевой слой (I/O) ───────────────────────────────────────────────────

proc recvExact*(socket: Socket | AsyncSocket; n: int): Future[string] {.multisync.} =
  result = ""
  # Можно использовать newStringOfCap(n) для оптимизации аллокаций
  while result.len < n:
    let chunk = await socket.recv(n - result.len)
    if chunk.len == 0:
      raise newException(IOError, "Connection closed while reading " & $n & " bytes")
    result.add(chunk)

proc readFrame*(socket: Socket | AsyncSocket): Future[Frame] {.multisync.} =
  # 1. Читаем ровно 15 байт через recvExact (гарантия полного чтения)
  let headerStr = await socket.recvExact(FrameHeaderSize)
  
  # Используем устоявшийся в кодовой базе паттерн (cast[seq[byte]])
  let hbytes = cast[seq[byte]](headerStr)
  
  # 2. Декодируем чистой функцией
  let (length, opcode, flags, version, reqId) = decodeHeader(hbytes)
  
  var f = Frame(
    opcode: opcode,
    flags: flags,
    version: version,
    requestId: reqId
  )

  # 3. Читаем полезную нагрузку через recvExact, если она есть
  if length > 0:
    let payloadStr = await socket.recvExact(int(length))
    f.payload = cast[seq[byte]](payloadStr)
  else:
    f.payload = @[]

  return f

proc writeFrame*(socket: Socket | AsyncSocket; f: Frame) {.multisync.} =
  # 1. Кодируем заголовок чистой функцией (она сама возьмет f.payload.len)
  let headerBytes = encodeHeader(f)

  # Конвертируем array в string для сокета
  var headerStr = newString(FrameHeaderSize)
  copyMem(addr headerStr[0], unsafeAddr headerBytes[0], FrameHeaderSize)
  
  # 2. Отправляем заголовок
  await socket.send(headerStr)

  # 3. Отправляем payload, если есть
  if f.payload.len > 0:
    # Здесь тоже можно использовать cast для быстрого преобразования без копирования
    let payloadStr = cast[string](f.payload)
    await socket.send(payloadStr)
