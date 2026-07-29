type Frame* = object
     opcode*:     uint8
     flags*:      uint8
     version*:    uint8
     requestId*:  uint64
     payload*:    seq[byte]

