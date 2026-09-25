# AGENTS.md

本文件是 omp 的项目上下文（native provider 路径 `.omp/AGENTS.md`，会话启动时自动注入），供在本仓库工作的 AI 编码代理遵循。仓库无 Claude Code 专属配置；如需工具级开关，放在 `.omp/config.yml`。

## 项目是什么

面向 Debian/Ubuntu 个人 VPS 的基础安全初始化脚本集。**没有编排器**——人是编排器：README 提供每步命令（raw 拉取 `bash <(curl -sL .../NN-xxx.sh)`），脚本按步骤号执行（01/02/04/05/06/07/08/09/12；3/10/11 为手动命令/提示，跳号是有意的）。架构决策见 `docs/adr/0001-no-orchestrator.md`（不要提议加总控脚本/init.sh，已被否决过）。

## 常用命令

```bash
bash -n <脚本> && shellcheck -S warning <脚本>   # 每个脚本改完必须双绿
bash tools/sync_check.sh                          # 改公共函数/公共变量/包清单后必须跑，输出"一致性 OK"才算过（职责见「文档结构」）
```

无构建、无测试框架——本地验证手段就是上述两条 + 真机验收（在 Snapshot 保护的 VPS 上走全流程）。

## 架构与硬约束

- **自包含脚本**：每个脚本单文件可独立 raw 拉取运行，公共函数内联（不 source 仓库内文件）。`tools/sync_check.sh` 对 21 个公共函数做跨脚本 md5 对比——**改任何公共函数必须同步全部脚本并通过该工具**，否则一致性即失守（2026-09-23 曾出现 9 个函数分歧）。该工具的完整职责见「文档结构」一节。
- **三条铁律**（README 顶部）：UFW 先于 sshd；密钥先于禁密码；改 sshd 后旧会话不关。06-ssh.sh 用前置自检 + 双闸门落实，改动 05/06/12 时不得破坏此链路。
- **配置继承**：跨脚本参数存 `/root/.vps-init.conf`（VPS 本地，600 权限，永不进仓库，见 `.gitignore`）。键表在 README「参数只输一次」节。公共块含 conf_has/conf_read/conf_write/conf_get/conf_update——`conf_update` 有 sed 注入加固（`\ | &` 转义），**改 conf 值一律用它而非裸 sed**。
- **防锁死设计**：全部脚本强制 TTY（拒绝无人值守/cloud-init）；05 临时放行旧端口（不假设 22，厂商随机端口兼容，conf 键 `OLD_SSH_PORT`），06 闸门确认后才删除；所有写配置前 `backup_file` 到 `/root/vps-init-backups/`，无自动回滚。
- **统一代码风格基准**：`04-user.sh` 的公共块是事实标准（最大最全）；`08-swap.sh` 自有 helper 体系（`ask_option`/`confirm` 等）与 `set -uo pipefail`（不开 `-e`），保留其风格、不并入公共块，但**已纳入本仓库维护**（2026-09-26 起，改动同样要过双绿 + `sync_check`）；`09-bbr.sh` 参数集为用户本机特调（勿代改）。

## 工作区规范（保持干净、结构化）

- **根目录只放**：步骤脚本 `NN-xxx.sh`、两个入口文档（`README.md`/`CONTEXT.md`）与仓库配置（`.gitignore`/`.gitattributes`）。其他一切进 `docs/`、`tools/`、`.omp/`。禁止在根目录堆放临时/备份/试验文件。
- **脚手架一律离开仓库**：测试脚本、调试输出、提交消息草稿、历史改写脚本、中间产物（`*.bak`/`*.old`/`newXX.sh`）放 `/tmp`（Windows 侧为 `E:/tmp`），**任务结束即删**，不留待下次。
- **不留空目录、不留游离残渣**：空目录（如误建的 `E/`、`E/.ssh`）对 git 无影响但污染工作区，发现即删；路径拼错产生的杂项同理。
- **交付前 `git status` 必须干净**：无未跟踪文件、无 stash、无未推送提交；`git status -sb` 应显示与 `origin/main` 同步。
- **历史改写/强推之后**：`git reflog expire --expire=now --all && git gc --prune=now` 清掉不可达对象，并确认远端无残留分支/标签。

## 文档结构

- `README.md`：唯一操作手册（用户视角），改脚本行为时同步"做什么"描述与 conf 键表
- `docs/tutorial.md`：手动教程，与脚本行为保持等价（脚本改了它也要跟）
- `CONTEXT.md`：术语表（闸门/前置自检/自包含脚本等），措辞以此为准
- `tools/sync_check.sh`：公共块一致性自检，在**改公共代码后拦住"只改了一个脚本"的失守**。检查四项：
  1. **21 个公共函数跨脚本一致**（md5 比对函数体）——内联复制机制下，任一脚本被单独修改即报警
  2. **`CONF`/`BK_ROOT` 变量一致**——取值须跨脚本相同；被使用就必须有定义（set -u 下漏定义即崩，2026-09-26 的事故）
  3. **包清单与文档一致**——`02-tools.sh` 的 `BASE`/`TOOLS_EXTRA` 必须与 README、`docs/tutorial.md` 对应清单逐项相同
  4. **脚本清单完整性**——预期脚本文件缺失/改名即报

  检查范围含 `08-swap.sh`（它不参与函数比对，但变量与文件存在性纳入）。输出 `=== 一致性 OK ===` 才算过。

## 已知教训（新会话必读）

- **多行带转义的 bash 块禁用 python/perl 程序化替换**（本仓库历史上连续多次产出损坏代码：字面 `\n`、0x01 控制字节、函数体截断）。改脚本优先用 Edit 逐块，程序化操作后立刻 `bash -n` + shellcheck。
- Windows 环境注意：`.gitattributes` 强制 LF（CRLF 会让 raw 拉取的脚本在 Linux 上炸）；python subprocess 读 git 输出要显式 `encoding='utf-8'`（本地默认 GBK）。
- 推送到远端前先征得用户确认（用户明令要求）。
- **脚手架不进仓库**：测试脚本/提交消息草稿/中间产物一律放 `/tmp`（Windows 侧 `E:/tmp`），任务结束即删——历史上 `E:/tmp` 累积过 49 项会话残留，仓库根目录也曾出现拼错路径产生的空目录 `E/`。
