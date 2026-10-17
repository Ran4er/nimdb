type
  ClientOpcode* = enum
    opHello = 				0x01
    opQuery = 				0x02
    opPrepare = 			0x03
    opExecute = 			0x04
    opCancel = 				0x05
    opBegin = 				0x06
    opCommit = 				0x07
    opRollback = 			0x08

    opVectorInsert = 	0x10
    opVectorSearch = 	0x11
    opVectorRange = 	0x12

    opGraphQuery = 		0x20
    opGraphMutate = 	0x21

    opTrainModel = 		0x30
    opPredict = 			0x31

    opStreamFetch = 	0x40

    opPing = 					0x50
    opClose = 				0x51

    opAdmin = 				0xF0

  ServerOpcode* = enum
   opHelloAck =			0x80
   opResultMeta = 		0x81
   opDataChunk =			0x82
   opResultDone =		0x83
   opRowCount =			0x84
   opPreparedAck =		0x85
   opTxnAck =				0x86
   opVectorResult =  0x87
   opGraphResult =   0x88
   opTrainStarted =  0x89
   opTrainProgress = 0x8A
   opTrainDone =			0x8B
   opModelInfoResp = 0x8C
   opPong =					0x90
   opError =					0xE0
   opNotice =				0xE1
   opServerEvent =		0xF0

proc toClientOpcode*(b: uint8): Option[ClientOpcode] =
  for op in ClientOpcode:
    if ord(op) == int(b):
      return some(op)
  none(ClientOpcode)

proc toServerOpcode*(b: uint8): Option[ServerOpcode] =
  for op in ServerOpcode:
    if ord(op) == int(b):
      return some(op)
  none(ServerOpcode)
