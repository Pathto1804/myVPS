# AGENTS.md

本文件是 omp 的项目上下文（native provider 路径 `.omp/AGENTS.md`，会话启动时自动注入），供在本仓库工作的 AI 编码代理遵循。仓库无 Claude Code 专属配置；如需工具级开关，放在 `.omp/config.yml`。

## 项目是什么

面向 Debian/Ubuntu 个人 VPS 的基础安全初始化脚本集。**没有编排器**——人是编排器：README 提供每步命令（raw 拉取 `bash <(curl -sL .../NN-xxx.sh)`），脚本按步骤号执行（01/02/04/05/06/07/08/09/12；3/10/11 为手动命令/提示，跳号是有意的）。架构决策见 `docs/adr/0001-no-orchestrator.md`（不要提议加总控脚本/init.sh，已被否决过）。

## 常用命令

```bash
bash -n <脚本> && shellcheck -S warning <脚本>   # 每个脚本改完必须双绿
bash tools/sync_check.sh                          # 改公共函数/公共变量（CONF、BK_ROOT）后必须跑，输出"一致性 OK"才算过
```

无构建、无测试框架——本地验证手段就是上述两条 + 真机验收（在 Snapshot 保护的 VPS 上走全流程）。

## 架构与硬约束

- **自包含脚本**：每个脚本单文件可独立 raw 拉取运行，公共函数内联（不 source 仓库内文件）。`tools/sync_check.sh` 对 21 个公共函数做跨脚本 md5 对比，并检查 `CONF`/`BK_ROOT` 的跨脚本定义与取值一致（2026-09-26 起）——**改任何公共函数或这两个变量必须同步全部脚本并通过该工具**，否则一致性即失守（2026-09-23 曾出现 9 个函数分歧；2026-09-26 曾出现 06/07/09 漏定义 `BK_ROOT` 而静态检查无声）。
- **三条铁律**（README 顶部）：UFW 先于 sshd；密钥先于禁密码；改 sshd 后旧会话不关。06-ssh.sh 用前置自检 + 双闸门落实，改动 05/06/12 时不得破坏此链路。
- **配置继承**：跨脚本参数存 `/root/.vps-init.conf`（VPS 本地，600 权限，永不进仓库，见 `.gitignore`）。键表在 README「参数只输一次」节。公共块含 conf_has/conf_read/conf_write/conf_get/conf_update——`conf_update` 有 sed 注入加固（`\ | &` 转义），**改 conf 值一律用它而非裸 sed**。
- **防锁死设计**：全部脚本强制 TTY（拒绝无人值守/cloud-init）；05 临时放行旧端口（不假设 22，厂商随机端口兼容，conf 键 `OLD_SSH_PORT`），06 闸门确认后才删除；所有写配置前 `backup_file` 到 `/root/vps-init-backups/`，无自动回滚。
- **统一代码风格基准**：`04-user.sh` 的公共块是事实标准（最大最全）；`08-swap.sh` 自有 helper 体系（`ask_option`/`confirm` 等）与 `set -uo pipefail`（不开 `-e`），保留其风格、不并入公共块，但**已纳入本仓库维护**（2026-09-26 起，改动同样要过双绿 + `sync_check`）；`09-bbr.sh` 参数集为用户本机特调（勿代改）。

## 文档结构

- `README.md`：唯一操作手册（用户视角），改脚本行为时同步"做什么"描述与 conf 键表
- `docs/tutorial.md`：手动教程，与脚本行为保持等价（脚本改了它也要跟）
- `CONTEXT.md`：术语表（闸门/前置自检/自包含脚本等），措辞以此为准
- `tools/sync_check.sh`：公共块一致性自检（21 个公共函数 + `CONF`/`BK_ROOT` 变量 + 脚本清单）

## 已知教训（新会话必读）

- **多行带转义的 bash 块禁用 python/perl 程序化替换**（本仓库历史上连续多次产出损坏代码：字面 `\n`、0x01 控制字节、函数体截断）。改脚本优先用 Edit 逐块，程序化操作后立刻 `bash -n` + shellcheck。
- Windows 环境注意：`.gitattributes` 强制 LF（CRLF 会让 raw 拉取的脚本在 Linux 上炸）；python subprocess 读 git 输出要显式 `encoding='utf-8'`（本地默认 GBK）。
- 推送到远端前先征得用户确认（用户明令要求）。
