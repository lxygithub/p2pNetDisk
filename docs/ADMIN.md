# 服务端管理后台

`netdiskd` 内置一个管理后台（HTTP），用于没有客户端时查看服务状态、管理回收站、
浏览与下载文件。页面是单文件 HTML，由服务端直接返回，**没有前端构建步骤**。

## 启动

管理后台随 `netdiskd` 一起启动，默认只监听本机：

```text
admin   : http://127.0.0.1:8088/
admin   : token = NETDISK_ADMIN_TOKEN 或 /mnt/datadisk/netdisk/secret/.admin-token
admin   : 远程访问 ssh -L 8088:127.0.0.1:8088 <user>@<host>
```

| 环境变量 | 默认 | 说明 |
| --- | --- | --- |
| `NETDISK_ADMIN_ADDR` | `127.0.0.1:8088` | 监听地址；`off` / `none` / `0` 关闭 |
| `NETDISK_ADMIN_TOKEN` | 自动生成 | 至少 8 位；留空则读写 `<secret 目录>/.admin-token`（0600） |

token 文件与 `secret.key` 同目录（`0700`），和用户文件物理隔离；文件名以 `.` 开头，
因此不会出现在网盘列表里，也无法通过 `safe_path` 访问。

## 访问

服务器本机浏览器直接开 `http://127.0.0.1:8088/`。从自己电脑访问推荐 SSH 隧道：

```bash
ssh -L 8088:127.0.0.1:8088 yuan@<host>
# 然后本地浏览器打开 http://127.0.0.1:8088/
```

取 token：

```bash
sudo -u yuan cat /mnt/datadisk/netdisk/secret/.admin-token
```

## 功能

**概览**：版本、运行时长、监听地址、数据目录、EndpointId（默认打码，点「显示」展开）、
relay、磁盘已用/剩余、文件数与总大小、回收站条目与占用。

**回收站**：

- 列表：原文件名、回收站内名（`<unix秒>-<原名>`）、大小、删除时间
- **恢复**：可改目标路径；目标已存在时拒绝覆盖，不会毁掉现有文件
- **下载**：先把文件从回收站取出来，再决定是否恢复
- **彻底删除 / 清空 / 清理 N 天前**：`purge` 按文件 mtime 判断，清空前有二次确认

**文件**：只读浏览目录、下载单个文件。上传 / 删除 / 重命名仍走客户端协议。

## 安全边界

- 默认只监听 `127.0.0.1`。需要局域网访问就用反代加 TLS 与额外认证，
  **不要**直接把 8088 挂到公网。
- 单 token + cookie session：`HttpOnly`、`SameSite=Strict`、12 小时过期；
  token 比较使用定长比较，避免计时侧信道。
- 所有写操作都是 `POST` + JSON；`SameSite=Strict` 已挡住跨站表单/脚本发起的请求。
- 路径穿越防护：文件下载走 `safe_path`（拒绝绝对路径、`..`、隐藏文件）；
  回收站条目只接受单层文件名。
- 不做多用户与角色：个人网盘没有权限模型，加角色只会扩大攻击面。
- EndpointId 默认打码显示，但仍可一键展开 —— 截图/录屏前注意。

## 已知限制

- 「概览」与「文件」都基于 `list_entries` 全量递归扫描：文件上万时页面会慢，
  但扫描在 `spawn_blocking` 里，不会卡住传输。后续可换 SQLite 索引。
- 回收站只包含**文件**：服务端拒绝删除目录，所以没有目录恢复。
- 原文件名以「数字-」开头时（如 `123-a.txt`），恢复可能被误认为同秒序号而少一段；
  恢复弹窗里可以手动改目标路径。
- 没有审计日志与操作历史。

## 与客户端协议的关系

管理后台直接读写数据目录，不经过 QUIC 协议：

- 不需要改 `Request` / `Response`，旧客户端不受影响；
- 与客户端传输并发时靠文件系统语义保证一致性（恢复用 `rename`，目标存在即拒绝）；
- 将来做「客户端回收站」时可以复用 `netdisk-core` 的 `list_trash` /
  `restore_from_trash` / `delete_trash_entry` / `purge_trash`。

## 服务端部署

`infra/systemd/netdiskd.env.example` 已包含两个变量；改完 env 后：

```bash
sudo systemctl restart netdiskd
sudo journalctl -u netdiskd -n 20 --no-pager
```

日志里出现 `admin   : http://127.0.0.1:8088/` 即启动成功。端口被占用时只打印
`管理后台未启动`，**不会**影响 QUIC 传输服务。
