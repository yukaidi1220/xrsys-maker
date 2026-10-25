# 镜像开机测试（image-boot-test.yml）设计说明

> 依据 2026-10-25 runner-probe.yml 实测：windows-latest 上 HypervisorPresent=True，
> **WHPX 加速可用**（失败自动回退 TCG），choco 安装 QEMU 11.x 正常，自带 edk2 UEFI 固件，
> qemu-img 原生支持 VHDX，TCG 兜底启动 Alpine 61MB 仅 15 秒。

## 流程

1. **取 ESD**：输入 `metadata_json`（nightly 指针，取 `sys.url`）或直接 `esd_url`。
2. **建盘**：`qemu-img create -f vhdx` 建动态盘 → diskpart `attach vdisk` 后转 GPT，
   建 100MB EFI（FAT32，盘符 Y:）+ 16MB MSR + 主分区（NTFS，盘符 V:）。
   *makexrsys.ps1 的构建流程只有单个 NTFS 主分区、无引导——那是采集回 ESD 用的，不用能开机；
   本测试补的就是 EFI 分区和 bcdboot。*
3. **释放**：`wimlib-imagex apply image.esd <index> V:\`。ESD 是 LZMS 固实压缩，
   5-6GB 实测要 10-20 分钟，步骤有 5 分钟一次心跳。
4. **写引导**：用**镜像里自带的** `V:\Windows\System32\bcdboot.exe` 写 `/s Y: /f UEFI`。
5. **开机**：`-machine q35 -accel whpx -accel tcg`（多个 `-accel` 依次回退），AHCI/SATA 总线
   （**不要用 virtio**：镜像里没有 virtio 驱动会蓝屏/找不到盘），e1000 网卡走 user-mode NAT，
   `-display none` + QMP 走 `tcp:127.0.0.1:4444`。
6. **截图**：每 3 秒 QMP `screendump` 一张 PPM；**画面哈希去重**——只有画面变化（或每 100 张）
   才进 artifact，静止画面只计数。连续 10 张（约 30 秒）无变化判定"到达桌面/静止"提前结束。
7. **上传**：`shots/ + qemu-stderr.log` 打 artifact（保留 7 天），人工翻看确认进桌面。

## 镜像索引（多版本母盘）

MSUpdate 的多版本转换以**家庭中文版（CoreCountrySpecific）为母盘**，DISM `/Set-Edition`
依次追加（见 MSUpdate/msupdate.ps1 `:makefromccs`）。全成功时索引为：
`1=家庭中文版 2=家庭版 3=家庭单语言版 4=专业版 5=专业工作站版 6=教育版 7=企业版 8=IoT企业版`。
**老批次镜像（如 2024-10 的 21H2）没有多版本转换，只有索引 1**——makexrsys.ps1 已改为按
映像名匹配，本工作流的 `image_index` 手动指定时注意。跑 `wimlib-imagex info image.esd`
可列出实际索引。

## 已知风险 / 调参

- **apply 慢**：LZMS 固实压缩，是流程里最耗时的一步；WHPX 下开机本身反而快（Win11 进桌面
  量级 5-15 分钟，取决于镜像内自动部署脚本）。`run_minutes` 默认 40，OOBE 慢的镜像可给 60。
- **virtio 陷阱**：见上，坚持 AHCI。
- **VHDX 锁**：diskpart detach 必须成功再启动 QEMU，否则文件被宿主锁住 QEMU 打不开。
- **WHPX 偶发**：若 whpx 启动失败，`-accel tcg` 兜底，速度约慢一个量级但能跑完。
- **屏幕判定从简**：哈希稳定≠一定进桌面（也可能卡死在同一画面），artifact 人工确认；
  后续可加 OCR/特定区域检测，先用人工翻图跑起来。
- **artifact 体积**：去重后通常几十 MB（开机画面变化次数有限）；不去重 40 分钟能到 1GB+。

---

## 2026-10-26 定型版（覆盖上文过时描述）

经 2026-10-25 一整天约 30 个 run 的实测迭代，工作流已定型如下。

### 检查范围

- 被测对象：`esd_url`（默认 7/22 备份的 26H1 nightly ESD 固定一版；nightly 构建恢复后可接 latest 指针）
- 能抓的病：引导失败（bcdboot 产物坏/BCD 损坏）、蓝屏（黑屏 BSOD 有画面+dump）、
  部署链卡死、错误页循环、"会动的尸体"（画面变化但实为循环）
- 抓不到的病：软件装好没装好、功能正确性、性能、真机差异（只看屏幕）
- 硬件面：WHPX 加速 + `-cpu Skylake-Client`（qemu64 两分半必崩 VP exit 4；
  kernel-irqchip=off 早期挂死；TCG 从未引导成功过，均拉黑）

### 判定语义（verdict）

| verdict | 含义 | job 颜色 |
|---|---|---|
| `desktop` | 主画面（剔除任务栏条）静止 30s 且右下角时钟区走动 → 空闲桌面 | 绿（提前结束）|
| `deployed` | QMP 收到 SHUTDOWN 事件（客户机发起关机）= 部署脚本按设计收尾 | 绿（提前结束）|
| `timeout` | 预算用完但画面仍在活动（部署长尾/慢）| 绿 |
| `frozen` | 主画面静止 300s 且时钟区死寂 | 红 |
| `loop` | 同一画面第 8 次成为稳定期（≥3 帧）→ 蓝屏进度循环/错误页重试循环 | 红 |

双区域分区实测：任务栏顶 y=753 高 47px（1280x800），时钟在右下角；
主画面=上 744 行、时钟带=底部 56 行中右侧 300px 角落矩形（避开底部居中的固件转圈）。

### 关键坑台账（都有 run 实锤）

- **VHDX+QEMU 拉黑**：动态扩容损坏（QEMU#727，仅 VHDX 中招，qcow2/raw/VMDK/VDI/VPC 均无损）；
  writethrough 模式退出时截断文件（BAT 越界）；qemu-img 产物被 diskpart 拒（稀疏，QEMU#136）。
  **默认磁盘=qcow2**（diskpart 建 VHDX 释放后 `qemu-img convert` 转换，取证时转回 fixed 子格式副本）。
- **bootmgfw_EX 60 连败是固有噪音**：镜像 EFI_EX 文件齐全，bcdboot 的 0x3 是其内部
  GLOBALROOT 路径解析问题，引导靠 bootx64 回退路径一直正常，每局白烧约 1 分钟，无解不修。
- **取证挂载**：Stop-Process 后句柄未释放（Wait-Process 90s 解决）；qcow2 取证副本必须
  `-o subformat=fixed`（稀疏副本 diskpart 拒挂）；diskpart 输出留痕 + Mount-DiskImage 兜底。
- **QEMU 秒退**：WHPX 偶发启动后数秒即死（stderr 无致命行），QMP 连接带重试、按轮失败处理。
- **部署链实测**：多次重启 + 桌面任务（万能驱动→VC/.NET/Bandizip/办公字体…）→正常关机，
  全程 >60 分钟，`run_minutes` 默认 100，开机上限默认 8 次。

### 产物

- `boot-shots-<index>-a<attempt>-<run_id>`：去重截图/各轮 stderr/verdict/取证
  （minidump/Panther/System.evtx/Application.evtx/bcd-enum.txt）
- `boot-video-<run_id>`（仅绿局）：去重帧转 H.265 MP4（5fps、crf30、只取 1280x800，
  小分辨率早期帧丢弃）
- nightly：每天 UTC 17:40（01:40 CST）触发（GitHub 高峰可能延迟甚至吞班，已观察）；
  双 attempt 并行对冲宿主机差异（attempt 1 失败不算数，attempt 2 定胜负）
