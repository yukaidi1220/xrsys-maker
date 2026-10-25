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
