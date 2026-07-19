#ifndef NOW_CONTRACT_H
#define NOW_CONTRACT_H

/* Mirrors contract/asyncapi.yaml. The revision gates the hello handshake;
   unequal revisions refuse. */
#define kNowContractRevision 1
#define kNowDefaultHostPort  5250
#define kNowDefaultChunk     8192

/* Frame header: 8 bytes big-endian — channel u8, flags u8, transfer u16,
   payload length u32. PPC is big-endian, but build the bytes explicitly so
   the layout is the contract's, not the compiler's. */
#define kNowFrameHeaderBytes 8
#define kNowChannelControl   0
#define kNowChannelBulk      1
#define kNowFlagEnd          0x01
#define kNowMaxPayload       32768L

#endif
