# FPGA Architecture Diagrams

These diagrams document the active control relationships without inventing explicit RTL state names.

## Camera capture implicit ASM

```mermaid
stateDiagram-v2
    [*] --> Waiting
    Waiting --> Sampling : synchronized PCLK pulse and HREF
    Sampling --> Sampling : HREF remains high
    Sampling --> Boundary : HREF falls
    Boundary --> Commit : byte count is 128
    Boundary --> DiagnosticDrop : byte count is not 128
    Commit --> Waiting
    DiagnosticDrop --> Waiting
```

## Line Buffer read/write interlock

```mermaid
sequenceDiagram
    participant C as Camera_Capture
    participant L as Line_Buffer
    participant A as Arbitration
    C->>L: write bytes while HREF is valid
    C->>L: line_end and metadata
    L->>L: commit slot and increment committed_count
    L->>A: request while committed_count != 0
    A->>L: grant one lane
    L->>A: byte/valid/last
    A->>L: ready
    L->>L: release only after last handshake
```

## Arbitration authorization

```mermaid
flowchart TD
    R0[request0] --> RR[round-robin selector]
    R1[request1] --> RR
    R2[request2] --> RR
    R3[request3] --> RR
    RR --> G[one-hot grant lock]
    G --> P[128-byte packet]
    P --> H{valid && ready && last}
    H -->|no| G
    H -->|yes| N[advance rr pointer]
    N --> RR
```

## Byte Replacer CRC processing

```mermaid
flowchart LR
    B[accepted input byte] --> I{offset}
    I -->|4| CAM[replace cam_id]
    I -->|13| STATUS[replace FPGA status]
    I -->|other 0..125| PASS[pass byte]
    CAM --> CRC[CRC accumulator]
    STATUS --> CRC
    PASS --> CRC
    CRC -->|offset 126/127| TAIL[emit regenerated CRC]
```

## Byte FIFO TX/RX/CNT relationship

```mermaid
flowchart LR
    U[upstream valid/ready/last] --> TX[TX write logic]
    TX --> MEM[9-bit FIFO memory]
    MEM --> RX[RX read logic]
    D[downstream ready] --> RX
    TX --> CNT[CNT occupancy]
    RX --> CNT
    CNT --> READY[full/almost-full ready control]
```

## Ethernet and Host receive chain

```mermaid
flowchart LR
    P[packet valid/last] --> FA[Ethernet frame adapter]
    FA --> MF[Taxi MAC/MII FIFO]
    MF --> RB[RMII transmitter]
    RB --> PHY[PHY]
    PHY --> NIC[Host NIC]
    NIC --> NP[Npcap]
    NP --> PARSE[Host parser and CRC audit]
```

## CRC dual-layer audit decision

```mermaid
flowchart TD
    E{Host egress CRC valid?}
    E -->|no| CORRUPT[egress path corruption]
    E -->|yes| S{FPGA status bit 0x10?}
    S -->|no| OK[ingress and egress pass]
    S -->|yes| INGRESS[MCU to FPGA ingress CRC error]
```

## Host frame reassembly state view

```mermaid
stateDiagram-v2
    [*] --> AwaitRow0
    AwaitRow0 --> Collect : row_idx 0 or new frame_id
    Collect --> Collect : accepted row and expected next row
    Collect --> Complete : row_idx 479 and final-line condition
    Collect --> Incomplete : timeout, missing row, duplicate, or jump
    Incomplete --> AwaitRow0
    Complete --> AwaitRow0
```

The Host implementation represents these states through frame-id/row-index maps and result records rather than a single enum state variable.
