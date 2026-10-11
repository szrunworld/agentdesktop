# 安装与首次使用

适用于 Agent Desktop 0.1.x（macOS 14+，Apple 芯片）。支持范围见 [支持矩阵](support-matrix.md)，出错时查 [故障场景](troubleshooting.md)。

## 1. 获取并核对

每次构建产出两个文件（`scripts/bundle-app.sh`，CI 的 `Agent-Desktop-archive` 制品）：

- `Agent Desktop-<build>.zip`：保留完整 `.app` 结构的归档；
- `Agent Desktop-<build>.manifest.json`：归档和包内每个文件的 SHA-256，以及源码提交（`engine.source`）。

核对：

```bash
scripts/verify-archive.sh "Agent Desktop-<build>.zip" "Agent Desktop-<build>.manifest.json"
# 没有仓库时，至少比对归档本身：
shasum -a 256 "Agent Desktop-<build>.zip"   # 应等于 manifest 里的 archive.sha256
```

包内 `Contents/Resources/build.json` 记录同一个源码提交和签名前的二进制哈希；`agentdesktop version` 打印的 `build.source` 也是它。三处一致才说明拿到的就是那次构建。

## 2. 安装

把 `Agent Desktop.app` 拖进「应用程序」，然后打开它。它是菜单栏应用（没有 Dock 图标），主窗口从菜单栏图标打开。

> **开发包**（`0.1.0-dev`，本地自签名）没有公证，从浏览器、聊天工具下载的 zip 会被 Gatekeeper 隔离，双击提示无法打开。仅限内部测试时，确认来源和哈希后可去掉隔离属性：
> `xattr -dr com.apple.quarantine "/Applications/Agent Desktop.app"`
> 正式版本经 Developer ID 签名与公证，不需要这一步（[S4 门禁](a4-release-gate.md)）。

## 3. 授予系统权限

Agent Desktop 需要两项权限，都授予 **Agent Desktop** 本身（不是终端）：

| 权限 | 用途 | 位置 |
| --- | --- | --- |
| 屏幕录制 | 截取绑定窗口、主窗口预览 | 系统设置 › 隐私与安全性 › 屏幕与系统音频录制 |
| 辅助功能 | 读取界面元素、后台输入 | 系统设置 › 隐私与安全性 › 辅助功能 |

授权跟签名证书绑定：同一证书签的新版本覆盖安装后授权仍然有效；换证书（例如从开发包换成正式版）需要重新授权。

## 4. 把命令行放到 PATH

包内唯一的命令行是 `Contents/Resources/bin/agentdesktop`。建一个链接即可，CLI 会顺着链接找到所在的 App：

```bash
sudo ln -sf "/Applications/Agent Desktop.app/Contents/Resources/bin/agentdesktop" /usr/local/bin/agentdesktop
agentdesktop version
agentdesktop doctor          # 只读：端点、握手、版本、身份、两项权限
```

`doctor` 全部 ok（`authentication` 一项在配对前是 warn）即可继续。

## 5. 配对

每个程序（包括 CLI 自己）都必须先配对，才能读写任何 Desktop。配对前除了 `version`、`runtime start`、`runtime capabilities`、`doctor`，其余命令都返回 `pairing_required`（退出码 4）。

```bash
agentdesktop agents pair --name "我的脚本" \
  --capabilities observe,act,desktop.manage,run --desktops created --duration 8h
```

Agent Desktop 会弹出确认窗口（显示程序自报的名称和申请的范围），用户确认后凭据存进钥匙串（服务名 `com.agentdesktop.client-credential`）。授权只覆盖申请里写的能力、Desktop（`created` = 本程序自己创建的）、应用和时长；之后可用 `agentdesktop agents grant` 收窄、`agentdesktop agents revoke` 撤销（同样弹窗确认）。

MCP 客户端用自己的 profile 配对，再把 `mcp` 交给客户端：

```bash
agentdesktop agents pair --profile mcp --name "Claude Code" --capabilities observe,act,desktop.manage,run --desktops created
claude mcp add agentdesktop -- "/Applications/Agent Desktop.app/Contents/Resources/bin/agentdesktop" mcp
```

GUI 单元（`agentdesktop unit run`）默认关闭；需要时执行 `defaults write com.agentdesktop.app guiExecution -bool true`，重启 Agent Desktop，在设置里配置模型连接，并在授权里加上 `unit.run`。

## 6. 第一次跑通

```bash
D=$(agentdesktop desktop create --size 1280x800 --format json | jq -r .data.desktopId)
agentdesktop app launch --desktop $D --bundle-id com.apple.calculator
```

完整流程（绑定窗口、observe、act、session exec、Run）见 [CLI 说明](../cli/README.md)。

## 升级

退出 Agent Desktop，替换 `/Applications/Agent Desktop.app`，再打开。记录、配对和授权都保留在下面的数据目录里。若新版本换了签名证书，需要重新授予两项系统权限；从开发包换到正式签名版本时还需要重新配对（正式版改用 Data Protection 钥匙串，不迁移旧凭据）。

## 卸载

```bash
osascript -e 'quit app "Agent Desktop"'
rm -rf "/Applications/Agent Desktop.app" /usr/local/bin/agentdesktop
# 以下会删除全部记录（请求账本、Run、截图产物、配对与授权、AI 配置）：
rm -rf "$HOME/Library/Application Support/AgentDesktop"
defaults delete com.agentdesktop.app 2>/dev/null
# 钥匙串里的客户端凭据（每个配对过的 profile 一条，重复执行直到提示找不到）：
security delete-generic-password -s com.agentdesktop.client-credential
# 系统权限：
tccutil reset ScreenCapture com.agentdesktop.app
tccutil reset Accessibility com.agentdesktop.app
```

数据目录 `~/Library/Application Support/AgentDesktop/` 的内容：`runtime.sock`（及 `.lock`）、`ai.sock`、`runtime/`（`requests.sqlite`、`runs.sqlite`、`hub.sqlite`、`ai.sqlite`、`artifacts/`）、`cli/requests.jsonl`（CLI 发出写请求前记下的 requestId）。
