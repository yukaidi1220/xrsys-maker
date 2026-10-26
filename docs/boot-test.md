# 镜像开机测试（image-boot-test.yml）设计与运维手册

> 2026-10-26 定稿（约 30 个 run 实测迭代收敛）。定位：nightly 自动抽查 EEEOS 镜像
> "能不能真的开机、部署、收尾"，GitHub 托管 windows runner + QEMU(WHPX) 全自动，
> 产物 = 去重截图 + H.265 视频 + 盘内取证。

## 一、检查范围

- 被测对象：`esd_url`（默认 7/22 备份的 26H1 nightly ESD 固定一版；nightly 构建恢复后可接 latest 指针）
- 能抓的病：引导失败（bcdboot 产物坏/BCD 损坏）、蓝屏（Win11 黑底 BSOD 有画面+dump）、
  部署链卡死、错误页循环、"会动的尸体"（画面变化但实为循环）
- 抓不到的病：软件装好没装好、功能正确性、性能、真机差异（只看屏幕）

## 二、流水线

1. 装 QEMU/wimlib（choco + Tool_Resource）→ aria2c 下载 ESD
2. diskpart 建原生 VHDX（60GB 动态）→ GPT → EFI(FAT32,Y:) + 主分区(NTFS,V:)。
   *qemu-img 建的 VHDX 是稀疏文件被 diskpart 拒挂（QEMU#136）；convert gpt 自动建 MSR*
3. `wimlib apply`（5min 心跳）→ **完成后立刻删 ESD**（D: 实测 131GB 富余）
4. 写引导：**宿主** bcdboot（镜像自带的在宿主上 exit -1058471934 不可用）+ 硬校验
   （三文件存在 + bcdedit 枚举 default 指向 winload.efi）+ MD5 溯源
5. （默认）`qemu-img convert` 转 **qcow2** 后删 VHDX，约 90s
6. QEMU 开机：`q35 + whpx + -cpu Skylake-Client + -smp 4 -m 6G`、AHCI+e1000+OVMF、
   `-no-reboot`、QMP tcp:4444。客户机重启 → QEMU 退出 → 外层重拉（上限 boot_rounds 次）。
   QMP 断连/秒退有重试，按轮失败处理不掀翻步骤
7. 判定（见下）→ 绿局转视频 → 赛后取证（重挂盘拷 BCD 枚举/Panther/minidump/evtx；
   qcow2 先转 **fixed 子格式**副本——稀疏副本被 diskpart 拒挂）→ 双 artifact 上传

## 三、判定语义（verdict 红绿表）

| verdict | 触发条件 | 颜色 |
|---|---|---|
| `desktop` | 主画面静止 30s + 右下角时钟区跳变 → 空闲桌面，提前结束 | 绿 |
| `deployed` | QMP 收到 SHUTDOWN 事件（客户机发起关机）= 部署按设计收尾，提前结束 | 绿 |
| `timeout` | 预算用完但画面仍在活动（部署长尾） | 绿 |
| `frozen` | 主画面静止 300s 且时钟区死寂 | 红 |
| `loop` | 同一画面第 8 次成为稳定期（≥3 帧）→ 蓝屏进度循环/错误页重试 | 红 |

**双区域分区**（实测 shot-0125 量得：任务栏顶 y=753 高 47px，时钟右下角右对齐）：
主画面 = 上 744 行（剔除任务栏条，否则时钟跳字会重置静止计数）；时钟带 = 底部 56 行中
**右侧 300px 角落矩形**（不用全宽底条——固件加载的转圈在底部居中，会被误当时钟）。
旧版两坑都踩导致 desktop 判定结构性不可达（30+ 局从未触发，2026-10-26 修复后首跑即触发）。

## 四、参数速查

| 参数 | 默认 | 备注 |
|---|---|---|
| run_minutes | 100 | QEMU 阶段墙钟，跨开机轮不重置；job 硬上限 300min |
| boot_rounds | 8 | 部署链多次开关机直至正常关机 |
| accel | whpx | irqchip=off 早期挂死；TCG 出不了固件，均拉黑 |
| cpu_model | Skylake-Client | qemu64 缺 Win11 指令 2.5min 必崩 VP exit 4 |
| smp | 4 | smp=1 引导不正常 |
| disk | **qcow2** | VHDX 拉黑（见大案一） |
| machine / nic | q35 / e1000 | pc=i440fx+老IDE 亦可用；nic=none 可去网卡 |
| attempts | 2 | 双 attempt 矩阵对冲宿主机抽风（拟观察一周后撤） |
| esp_native | false | 镜像 EX 文件覆盖 ESP（镜像缺 bootx64_EX，仅半可用） |
| image_index / mem_gb | 4 / 6 | 单映像 ESD 自动回退索引 1 |

nightly：`cron 40 17 * * *`（北京 01:40）。撞美国早高峰，GitHub schedule 延迟可达
30min+ 甚至吞班（已实测）；建议错峰改 UTC 04:40（北京午间）。

## 五、大案档案（默认值的来由）

1. **VHDX 拉黑（QEMU#727）**：VHDX 块驱动在动态扩容/块分配阶段丢数据，损坏在断开
   重连后才显现——"跑着没事、一重启就死"。是连环案总根因：桌面任务中瞬死（无 dump，
   盘已坏）、复位撕 BCD（0xc000000f）、关机后首开 0x7B、取证挂不上盘。社区对照：
   qcow2/raw/VMDK/VDI/VPC 均无损，唯独 VHDX。另 `cache=writethrough` 在 VHDX 上退出
   截断文件（BAT 越界 31MB）也勿用。
2. **win32kbase.sys 0xBE（唯一存疑镜像侧问题）**：.NET 安装任务中偶发一次，Win32 内核
   驱动写只读内存；与字体任务（办公字体.exe 写 1.1GB）多次同现，间歇性疑 SMP 竞态。
   qcow2 换盘后未再现，真机影响未知，dump 待抓现行。
3. **CRITICAL_PROCESS_DIED / 0x7B / BCD 撕坏**：多数为 VHDX 损坏的下游症状，qcow2 后消失。
4. **bcdboot 60 次重试 = 固有噪音**：镜像 EFI_EX 文件其实齐全，0x3 是 bcdboot 内部
   GLOBALROOT 路径解析问题；引导走 bootx64 回退一直正常，每局白烧约 1 分钟，无解不修。
5. **宿主机抽风**：同代码同时段连败/连绿、WHPX 偶发秒死（stderr 无致命行）。
   对策：双 attempt + QMP 重试 + 按轮失败自动重拉。
6. **配置死刑名单**：qemu64、kernel-irqchip=off、TCG、smp=1、cache=writethrough、
   镜像自带 bcdboot、esp 全宽底条判定。

## 六、运维 runbook

- **看结果**：job 红绿即总判；日志搜 `判定: ` 看 verdict、搜 `次开机` 看节奏
  （健康参考：~7min/~3min/~13min 三轮后收尾，随宿主机速度波动）
- **红局排查**：下载 `boot-shots-*` → `shots/` 帧号×3s 重建时间轴 →
  `forensics/bcd-enum.txt` → `System.evtx` 搜 BugCheck 1001 → 有 Minidump 上 WinDbg
- **绿局快验**：下载 `boot-video-<run_id>`（约 75s 看完；concat 每帧显式 duration 0.2s
  + 末帧重复列出，否则 demuxer 给图片零时长、视频"闪一下就没了"——实测踩过）
- **产物**：`boot-video-<run_id>`（仅绿局）+ `boot-shots-<index>-a<attempt>-<run_id>`
  （截图/verdict/取证/各轮 stderr），保留 7 天

## 附：多版本母盘索引

MSUpdate 多版本转换以家庭中文版（CoreCountrySpecific）为母盘 DISM /Set-Edition 追加：
`1=家庭中文版 2=家庭版 3=家庭单语言版 4=专业版 5=工作站 6=教育版 7=企业版 8=IoT企业版`。
老批次（21H2 等）无转换只有索引 1。`wimlib-imagex info` 可查实际索引。
