# 验收

单元测试 `swift test`（需要完整 Xcode，安装使用不需要）。

## 自动验收

需要 iPhone USB 在线且另有 Wi‑Fi，两条线路出口不同。

```bash
python3 acceptance/usb.py --claude
```

```bash
sudo bash acceptance/faults.sh "$USER" /tmp/faults.txt; cat /tmp/faults.txt
```

第一条约 40 项，`--claude` 用独立数据目录启动 Claude Desktop 第二实例，不碰正在使用的实例，会消耗约 30 MB 流量。第二条依次强杀守护进程、强杀转发器、停用 USB 网卡、清空和关闭防火墙，并抓包。

## 普通模式（第一阶段）

停止保护、退出 Guard，用普通方式打开 Claude，在 Claude Code 里运行（不需要密码，不查公网 IP）：

```bash
python3 acceptance/normal.py
```

## 真实应用

1. 按 README 启动 USB 会话。
2. 打开系统自带「终端」，先做**稳定运行**：运行下面的命令，5 分钟内逐项使用聊天、上传文件、内置浏览器、联网搜索、每个 MCP、Claude Code 命令、设置页，全程不要拔线。

```bash
python3 acceptance/watch.py 5
```

3. 再做**拔线恢复**：运行下面的命令，中途拔线 10 秒再插回，点「检查并恢复」，结束前要恢复成功。恢复检查期间 Claude 会被暂停几秒（界面没反应属正常），通过后继续。恢复后用**原来的 Claude 窗口**发一条消息、跑一次 Code。

```bash
python3 acceptance/watch.py 5 --unplug
```

两条命令结论为“没有发现泄漏”时退出码为 0，否则为 1。

再运行（不需要密码）：

```bash
python3 acceptance/shield.py
```

通过标准：`shield.py` 全部通过；默认线路上与该服务往来的包为「无」；正向对照大于 0；默认线路上属于受保护进程的包为「无」；UDP 外连 0 条；严格 DNS 打开时默认线路没有 DNS 查询；应用功能正常。
