# Camera to DDR4 AXI-Based Framebuffer

## 1. 项目概述

本项目旨在实现一个多摄像头（最高支持8路）视频采集系统，该系统将通过AXI4总线将视频数据实时存入DDR4内存。整个设计采用高度模块化的闭环控制系统，确保数据传输的稳定性和可靠性，并内置了必要的超时和溢出保护机制。

当前设计完成了视频数据从摄像头采集到写入DDR4内存的完整链路。

## 2. 模块功能说明

系统由以下几个核心Verilog模块构成：

*   **`Line_Generator` (LG)**
    *   **功能**: 每个摄像头通道对应一个LG实例。它负责接收摄像头的视频信号（`vsync`, `href`, `data`），并将每一行像素数据（如800像素）存入一个双缓冲（Ping-Pong）FIFO中。
    *   **核心机制**: 当其中一个缓冲区写满后，它会向 `Arbitration` 模块发出总线访问`request`。在获得授权后，它会将该缓冲区的数据发送给 `MUX_Machine`。

*   **`Arbitration` (仲裁机)**
    *   **功能**: 系统的“交通警察”。它接收来自所有 `Line_Generator` 的请求，并采用轮询（Round-Robin）策略，公平地为其中一个通道授予AXI总线访问权。
    *   **核心机制**: 发出`grant`（授权）信号锁定一个通道，在接收到`drawback`（撤销）信号后释放锁定。**该模块内置了一个不可配置的硬件看门狗定时器**，如果一个`grant`在规定时间（约10ms）内没有收到对应的`drawback`，定时器将强制触发`drawback`，释放总线锁，防止系统因下游模块（如AXI）卡死而全局冻结。

*   **`MUX_Machine` (数据选择器)**
    *   **功能**: 根据 `Arbitration` 发出的`grant`信号，从多个 `Line_Generator` 的输出中选择一个通道的数据流，并将其传递给 `AXI4_Compiler`。
    *   **核心机制**: `grant`信号使其锁定在一个通道上，直到`drawback`信号抵达才解除锁定。

*   **`Address_Generator` (AG)**
    *   **功能**: 一个纯组合逻辑模块，根据 `Arbitration` 提供的`cam_id`（摄像头ID）以及 `Line_Generator` 提供的`line_num`（行号）和`frame_num`（帧号），计算出当前数据行在DDR4内存中应存储的目标地址。

*   **`AXI4_Compiler`**
    *   **功能**: AXI4总线接口的核心。它接收来自 `MUX_Machine` 的16位像素流和来自 `Address_Generator` 的32位目标地址。
    *   **核心机制**: 模块内部包含一个宽度转换FIFO（16位输入，128位输出）。它首先将像素流打包成128位的AXI数据宽度，当FIFO中的数据量达到一次完整AXI突发（Burst）所需的数据量（100个128位字）时，它才向内存控制器发起一次AXI写操作。操作完成后（以接收到`bvalid`信号为标志），它会产生`drawback`脉冲，通知上游模块释放总线。

## 3. 架构与信号流

整个系统的工作流程是一个精确控制的闭环握手机制：

1.  **数据采集**: `Line_Generator` 捕获一行视频数据并存满一个内部FIFO。
2.  **请求总线**: LG向 `Arbitration` 发出 `request` 信号。
3.  **授权访问**: `Arbitration` 在轮询后选择一个LG，并发出 `grant` 信号。此 `grant` 信号同时发送给：
    *   目标 `Line_Generator`：允许其开始发送数据。
    *   `Address_Generator`：使其基于当前LG的`cam_id`、`line_num`和`frame_num`生成地址。
    *   `MUX_Machine`：使其选择正确的LG数据源。
    *   `AXI4_Compiler`：作为`permit`信号，允许其准备接收数据和地址。
4.  **数据传输**:
    *   LG将数据发送到 `MUX_Machine`。
    *   `MUX_Machine` 将数据转发到 `AXI4_Compiler`。
    *   `AXI4_Compiler` 将数据存入其内部的宽度转换FIFO。
5.  **AXI突发写入**: 当 `AXI4_Compiler` 的FIFO满足突发条件（存满100个128位字）后，它将锁存的地址和准备好的数据通过一次AXI突发（100个周期），写入DDR4内存。
6.  **释放总线**: AXI写操作的最后一个环节是内存控制器返回`B-Channel`响应。`AXI4_Compiler`在收到`bvalid`后，会生成一个单周期的 `drawback` 信号。
7.  **解除锁定**: `drawback` 信号被广播给 `Arbitration`、`MUX_Machine` 和 `Line_Generator`，使它们解除各自的锁定状态，准备处理下一个请求。`Arbitration` 的轮询指针（`rr_ptr`）也会移动到下一个通道。

## 4. 闭环机制深度分析 (“权利”模型)

为了确保系统的稳定，我们设计了四种“权利”交接的闭环机制。

#### 4.1. 控制权 (Control Rights)

*   **核心**: `grant` (授权) 与 `drawback` (撤销) 构成了唯一的控制权交接路径。
*   **流程**: `Arbitration` 是 `grant` 的唯一发出者，它将总线控制权交给下游。`AXI4_Compiler` 是 `drawback` 的唯一正常发出者，它在AXI事务结束后将控制权交还给 `Arbitration`。
*   **问题与对策**:
    *   **潜在问题**: "目前的`drawback`高度依赖`cnt`机制，如果`cnt`没有达到预期可能会导致AXI卡死在`W state`。" — 您提到的这个问题是致命的。如果 `AXI4_Compiler` 因为任何原因（例如，AXI总线`wready`一直为低）而无法完成100个字的突发计数，`drawback`信号将永远不会产生，导致系统全局死锁。
    *   **解决方案 (已实施)**: **`Arbitration`模块中的硬件看门狗（超时熔断机制）是这个问题的最终解决方案**。该机制现在是**永久启用**的。如果 `grant` 发出后，在预设的100万个时钟周期内没有收到`drawback`，仲裁机将强制产生一个`drawback`脉冲。这个脉冲会像正常信号一样，复位`Arbitration`、`MUX_Machine`和`Line_Generator`的状态，从而强行释放总线，避免系统被完全冻结。

#### 4.2. 数据权 (Data Rights)

*   **核心**: 数据流动的方向和时机由控制权和FIFO状态共同决定。
*   **流程**:
    1.  `grant`信号发出后，`MUX_Machine`立即锁定数据源，`cam_id`也随之确定。
    2.  `Line_Generator`根据其内部FIFO是否为空（`empty`）以及下游是否就绪（`px_ready`）来决定是否发送像素数据。
    3.  `AXI4_Compiler`则完全根据标准的AXI握手信号（`m_axi_wready`）来决定何时发送数据到总线。
    4.  传输完成后，`drawback`信号到达，`MUX_Machine`解除锁定。

#### 4.3. 地址权 (Address Rights)

*   **核心**: 保证一次AXI突发写入的地址在事务处理期间是绝对唯一的、不被改变的。
*   **问题与对策**:
    *   **潜在问题**: "如何避免在写的时候突然发生id翻动，导致地址出现严重的问题？" — 如果在一次传输中，`cam_id`或`line_num`等地址生成参数发生变化，将导致数据被写入错误的内存位置。
    *   **解决方案 (已实施)**: 本设计通过**双重锁存机制**来杜绝此问题：
        1.  **仲裁机锁定 `cam_id`**: 一旦 `Arbitration` 发出 `grant`，它就进入 `locked` 状态。在此期间，输出的 `cam_id` 是稳定不变的，直到 `drawback` 到来。
        2.  **AXI编译器锁存地址**: `AXI4_Compiler`在收到`permit`信号（即`grant`）的第一个周期，就会将 `Address_Generator` 计算出的完整32位地址 `cam_address` 锁存到其内部寄存器 `cam_address_hold` 中。后续的整个AXI事务都将使用这个锁存的地址，完全不受上游信号（`cam_id`, `line_num`等）后续任何变化的影响。

#### 4.4. 容量权 (Capacity Rights)

*   **核心**: 处理数据生产速度（摄像头输入）和消费速度（AXI写入）不匹配的问题，即“反压”和“溢出”处理。
*   **流程**:
    *   **反压 (Backpressure)**: 这是标准的`ready/valid`机制，从 `AXI4_Compiler` 的内部FIFO `full`信号一直反向传播到 `Line_Generator`，逐级暂停数据发送。
    *   **溢出熔断 (Overflow Fuse)**: 在 `Line_Generator` 中，如果一个新的数据行 (`href`有效) 到达，但用于接收该数据的FIFO缓冲区仍处于 `full` 状态（意味着上次的数据还没来得及被AXI总线处理），系统将触发**溢出熔断** (`in_overflow <= 1'b1`)。在此期间，所有新输入的像素数据都将被丢弃，直到当前行结束。这避免了用新数据冲刷未处理的旧数据，保证了已缓存数据的完整性，代价是丢弃一整行视频。

## 5. 后续进展

当前项目基本构建了从摄像头到DDR4内存的**存入**路径。一个完整的视频系统还需要**发送**（或称**读出**）路径，即从DDR4中读取帧数据并发送到显示设备（如HDMI或VGA）。

因此，后续工作除开验证当前架构外，还将围绕实现一个**读AXI模块**展开，该模块将：
1.  根据显示时序，从`Address_Generator`获取正确的读取地址。
2.  向内存控制器发起AXI读请求。
3.  接收来自DDR4的数据，并将其转换为视频像素流，发送给显示接口。
4.  可能需要一个新的仲裁机制来协调读/写操作对DDR4总线的访问。
<<<<<<< HEAD
=======


## 6. 进展情况

6/27 优化了以 Arbitration 和 AXI4 为核心的中央数据聚合链路。将 Line_Generator 等外设控制线统一精简为标准类 AXI-Stream 握手架构；增添 Grant_Splitter 级联模块以降低授权信号的物理扇出。在简化内部保护逻辑、提升系统最大工作频率的同时，确保了多通道突发写入 DDR 时的无死锁调度
>>>>>>> a1e0c1e (chore: First major revision)
