# vps-opt

面向 Ubuntu/Debian VPS 的调优与诊断脚本集合，仓库地址：<https://github.com/yuzeguitarist/vps-opt>

| 脚本 | 说明 |
|------|------|
| `ubuntu-tune.sh` | 系统维护与调优（计划优先，默认只读诊断；`apply` 需 root） |
| `vps-net-tune.sh` | 网络诊断与内核/网络栈调优（交互菜单；**需 root**） |

## 一行下载并运行

以下命令使用 `main` 分支的 Raw 地址；将脚本保存到 `/tmp` 再执行，避免管道执行时路径异常（尤其 `ubuntu-tune.sh` 会加载同目录下的扩展模块）。

### vps-net-tune.sh（网络调优）

```bash
curl -fsSL https://raw.githubusercontent.com/yuzeguitarist/vps-opt/main/vps-net-tune.sh -o /tmp/vps-net-tune.sh && sudo bash /tmp/vps-net-tune.sh
```

没有 `curl` 时可用 `wget`：

```bash
wget -qO /tmp/vps-net-tune.sh https://raw.githubusercontent.com/yuzeguitarist/vps-opt/main/vps-net-tune.sh && sudo bash /tmp/vps-net-tune.sh
```

### ubuntu-tune.sh（系统调优）

交互菜单（默认计划/诊断模式，多数情况可先不加 sudo；应用变更请用 root）：

```bash
curl -fsSL https://raw.githubusercontent.com/yuzeguitarist/vps-opt/main/ubuntu-tune.sh -o /tmp/ubuntu-tune.sh && bash /tmp/ubuntu-tune.sh
```

非交互、仅评估后一键应用（示例：`safe` + 自动确认）：

```bash
curl -fsSL https://raw.githubusercontent.com/yuzeguitarist/vps-opt/main/ubuntu-tune.sh -o /tmp/ubuntu-tune.sh && sudo bash /tmp/ubuntu-tune.sh apply --risk-level safe -y --non-interactive
```

查看全部子命令与选项：

```bash
bash /tmp/ubuntu-tune.sh help
```

（若尚未下载，可将上行中的 `/tmp/ubuntu-tune.sh` 换成本地已保存的路径。）

## 说明

- 目标环境主要为 **Ubuntu**（含 18.04/20.04/22.04/24.04 等，`systemd`）；其它 Debian 系可能部分功能降级。
- `vps-net-tune.sh` **必须** 以 root 运行（例如 `sudo`）。
- 脚本设计为默认尽量不改系统，实际改动前会给出计划与确认步骤；并支持生成回滚相关文件。生产环境仍建议先在小机或维护窗口试用。
