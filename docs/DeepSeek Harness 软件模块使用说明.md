# DeepSeek Harness 软件模块使用说明

本模块（`modules/software/deepseek-harness`）把 DeepSeek Harness 的浏览器界面（`dsh web`）注册成
systemd 系统服务，交给 LinuxApp 统一管理：安装、启动、停止、更新、回滚、修复、看日志与卸载。

三条核心设计：

1. **版本固定**：服务始终以某个**精确版本**的绝对路径启动，不使用 `npx ...@latest`，因此上游发布新版本时不会自动升级；只有你手动执行「更新」才会切换版本。
2. **状态取 systemd**：应用状态直接来自 `systemctl`（`is-active` / `is-enabled`），不额外做端口或 HTTP 探活，因此 `systemctl status` 看到的就是模块显示的状态。
3. **失败不自动回滚**：更新或启动失败时，模块打印报错与日志摘要、把状态标记为「异常」并停下来等你处理，同时在菜单里多出一个「回滚到上一版本」；应用**启动成功**后，历史版本与回滚点会被自动清理。

## 一、功能一览

| 动作 | 说明 |
| --- | --- |
| 安装 | 默认安装最新版本，也可指定精确版本或标签；自动注册并启用开机自启服务 |
| 启动 | 启动服务并等待进入运行状态；成功后清理历史版本与回滚点 |
| 停止 | 停止服务（保留开机自启设置与失败/回滚标记） |
| 更新 | 先提示插件风险 → 下载新版本 → 记录回滚点 → 停服务 → 改写服务启动版本 → 起服务并校验 |
| 回滚到上一版本 | **仅在状态为「异常」且存在回滚点时出现**；回到上一版本并删除失败版本 |
| 查看访问地址 | 重新从日志读取当前进程的访问地址（含 token）并刷新状态；即使 token 处于隐藏模式也完整显示（菜单里的动作名为「查看访问地址（含token）」，动作名不能带空格） |
| 修复服务文件 | 按当前版本重建 systemd 单元并重新设置开机自启（不联网、不改版本） |
| 查看最近日志 | `journalctl -u linuxapp-deepseek-harness` 最近 60 行 |
| 卸载 | 停止并禁用服务、删除单元；可选删除版本目录与 `DSH_HOME` 数据目录 |
| 查看状态 | 显示来自 systemd 的运行状态、启用的开机自启与访问地址（含 token） |

## 二、安装

菜单路径：`应用管理 → 软件模块 → DeepSeek Harness → 安装`。

安装前会自动检查：

- 需要 root（系统级服务与开机自启），非 root 会直接提示使用 `sudo`；
- 需要可用的 systemd；
- 需要 Node.js 20 或更高版本，缺失时由框架联动先调用「语言模块 → Node.js 运行时」安装（见第七节）。

安装过程会依次询问：

1. **安装源**：国内 npm 镜像（`registry.npmmirror.com`，默认）或官方源（`registry.npmjs.org`）。
2. **要安装的版本**：`1. 最新版本`（npm 标签 `latest`）或 `2. 手动输入版本号或标签`（例如 `0.1.5-rc.1`、`next`）。
3. **监听端口**：默认 `3080`，若被占用会提示你换一个端口。
4. **确认**：显示版本、监听地址、服务文件路径、`DSH_HOME` 与工作目录后确认。

> **监听地址固定为 `127.0.0.1`，不问也不允许改**：上游 `dsh web` 只支持绑定本机回环地址，指定内网地址或 `0.0.0.0` 都会直接启动失败，因此模块把它写死在 `DSH_FIXED_HOST` 里（见第十一节）。

安装完成后：

- 版本内容位于 `/opt/linuxapp/apps/deepseek-harness/versions/<精确版本>/`；
- 服务文件为 `/etc/systemd/system/linuxapp-deepseek-harness.service`，并已 `systemctl enable`；
- 服务被启动，模块会从日志里取出带 token 的访问地址并提示，状态里也直接显示这个**完整访问地址**（见第四节与第十一节）；
- 同时写入命令入口 `/usr/local/bin/linuxapp-dsh`，方便在任意 shell 里按当前精确版本管理插件。

目录结构：

```text
/opt/linuxapp/apps/deepseek-harness/
├── versions/<精确版本>/     # npm 安装结果（node_modules 内含 @deepseek-ai/dsh）
├── state                    # 模块状态文件（当前版本、回滚点、监听配置、访问地址）
├── cache/dsh-registry.json  # npm 元数据缓存（断网时兜底）
└── logs/                    # 失败时的诊断输出（systemctl status + journalctl 摘要）
```

`DSH_HOME` 默认为当前用户的 `~/.dsh`（root 服务即 `/root/.dsh`），里面保存会话、凭证、profile 与插件，
因此从手动 `npx @deepseek-ai/dsh@<版本> web` 迁移过来时数据不受影响。

## 三、开机自启与服务文件

服务单元由模块生成，关键内容如下（绝对路径、精确版本）：

```ini
[Unit]
Description=DeepSeek Harness Web GUI (linuxapp managed)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=root
WorkingDirectory=/root
Environment=HOME=/root
Environment=DSH_HOME=/root/.dsh
Environment=PATH=/opt/linuxapp/lang/nodejs/current/bin:/root/.dsh/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart="/opt/linuxapp/lang/nodejs/current/bin/node" "/opt/linuxapp/apps/deepseek-harness/versions/0.1.5-rc.1/node_modules/@deepseek-ai/dsh/lib/bin.js" web --host "127.0.0.1" --port "3080" --no-open
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
KillSignal=SIGTERM
StandardOutput=journal
StandardError=journal
SyslogIdentifier=linuxapp-dsh

[Install]
WantedBy=multi-user.target
```

说明：

- `ExecStart` 里是**精确版本目录**的入口文件，所以只要你不执行「更新」，服务版本不会变；
- `--no-open` 关闭浏览器交接（服务环境没有桌面），`--host 0.0.0.0` 被上游明确拒绝，本模块也不会使用；
- `Restart=on-failure` + `StartLimitBurst=3`：偶发崩溃会自动重启，持续失败会在约十几秒内进入 `failed`，模块据此把状态标为「异常」并停掉重启循环，等你处理；
- 常用排查命令：

```sh
systemctl status linuxapp-deepseek-harness
systemctl is-active linuxapp-deepseek-harness
systemctl is-enabled linuxapp-deepseek-harness
journalctl -u linuxapp-deepseek-harness -n 60 --no-pager
```

## 四、状态判定

模块把 systemd 状态映射为框架显示的状态行 `状态|版本|说明`，说明列里包含监听地址、开机自启状态与访问地址：

| systemd 情况 | 模块显示 |
| --- | --- |
| `is-active=active` | `运行中` —— 说明里含监听地址、开机自启状态与完整访问地址；若仍有历史版本或失败标记，会提示「选择「启动」即可清理」 |
| `is-active=inactive` 且上次操作失败 | `异常` —— 提示可修复后「启动」，或「回滚到上一版本」 |
| `is-active=inactive` 且无失败记录 | `已停止` —— 服务已安装但未运行 |
| `is-active=failed` 或处于 `activating`/自动重启 | `异常` —— 附带回滚提示 |
| 服务文件缺失但存在版本目录 | `异常` —— 提示执行「修复服务文件」 |
| 既没有服务文件也没有版本目录 | `未安装` |

状态里还会附带「Node.js 运行时不可用 / 版本过低」的提示，便于快速定位是不是运行环境的问题。

### 访问地址与 token

- 访问地址形如 `http://127.0.0.1:3080/?token=xxxxxxxx`，token 是**进程级**的，每次启动都会变化；
  模块在启动成功后从日志里读一次写入状态，状态行直接显示完整地址，复制到浏览器即可用。
- 状态显示「运行中」时给出的 token 就是**当前这次启动**的 token（启动时以日志时间戳窗口界定，不会读到上一次进程的旧值）；
  如果服务在模块之外被重启（例如 `systemctl restart`），状态里可能仍是上一次的 token，此时用「查看访问地址」重新读取即可。
- 需要隐藏 token 时：框架级 `./main.sh --hide-secrets`，或模块级 `LINUXAPP_DSH_HIDE_TOKEN=1`。
  隐藏后状态里只显示不含 token 的基准地址，并提示用「查看访问地址」查看；「查看访问地址」是显式动作，任何时候都完整显示。
- 命令行下可直接取用（便于脚本复制地址）：

  ```sh
  $ sh modules/software/deepseek-harness/module.sh status
  运行中|0.1.5-rc.2|服务 linuxapp-deepseek-harness.service 运行中（127.0.0.1:3080，开机自启已启用）；访问地址：http://127.0.0.1:3080/?token=xxxxxxxx
  ```

## 五、更新流程与插件风险

「更新」的执行顺序：

1. **插件风险提示**（每次都会打印，必须确认）：

   ```text
   [警告] 更新前请注意：如果你为 DeepSeek Harness 安装过插件（dsh plugin --profile web ...），
   新版本可能与插件不兼容，更新后服务可能启动失败。
   本模块在失败时不会自动回滚，服务会停在「异常」状态；
   你可以在菜单选择「回滚到上一版本」，或先移除不兼容插件后选择「启动」。
   ```

2. 确认依赖语言（Node.js）就绪；
3. 选择安装源与目标版本（与当前版本相同会提示「已是最新版本，无需更新」）；
4. **先把新版本完整下载并校验**到 `versions/<新版本>`，再动服务，避免停服后下载失败；
5. 记录回滚点（当前版本写入 `rollback_version`）；
6. 停止服务，并等待它真正停稳；
7. 重写服务文件的 `ExecStart` 为新版本并 `daemon-reload`；
8. 启动服务并等待进入运行状态；
9. **成功**：提示访问地址，并清理历史版本与回滚点；
   **失败**：打印 `systemctl status` 与 `journalctl` 摘要（完整内容存到 `logs/`），状态标记「异常」，不做自动回滚。

插件位于 `DSH_HOME/profiles/web`。更新后启动失败时，常用处理：

```sh
# 查看当前 profile 里的插件
/usr/local/bin/linuxapp-dsh plugin --profile web list

# 移除不兼容插件后，回到菜单选择「启动」
/usr/local/bin/linuxapp-dsh plugin --profile web remove <插件名>
```

如果插件一时无法处理，直接选「回滚到上一版本」即可回到更新前的状态。

## 六、失败处理与回滚

设计原则：**先给你报错，再给你选择，最后才清理。**

- 任何一次启动校验失败（安装、更新、启动、回滚）都会：
  1. 打印失败原因与最近日志（同时保存到 `/opt/linuxapp/apps/deepseek-harness/logs/`）；
  2. 把状态写为「异常」；
  3. **不自动回滚**，等待你处理。
- 状态为「异常」且存在回滚点时，模块菜单会**多出**一项「回滚到上一版本（<版本>）」。首次安装失败没有历史版本，因此不会出现该项，此时可修复后「启动」，或「修复服务文件」，或卸载重装。
- 回滚动作：停服务 → 服务文件改回上一版本 → 启动校验。
  - 回滚成功：删除失败的新版本目录，清空回滚点，状态回到「运行中」；
  - 回滚仍失败：两个版本都保留，状态保持「异常」，回滚项继续可用，可继续排查或再次回滚。
- **清理规则**：只要应用被确认启动成功（更新成功、修复后启动成功、回滚成功），就会删除历史版本目录、清空回滚点与失败标记，稳态只保留当前运行版本。设置 `LINUXAPP_DSH_KEEP_HISTORY=1` 可以改为「保留历史版本、只清理失败标记」。
- 「停止」不会清除失败标记与回滚点：异常状态需要靠「启动成功」或「回滚」来结束，避免误把回滚入口关掉。

## 七、语言联动（自动准备 Node.js）

DeepSeek Harness 是 Node.js 应用。本模块通过可选动作 `requires` 声明依赖 `nodejs`：

- 框架在进入模块菜单时会显示依赖状态（例如 `依赖语言 | Node.js 运行时：已安装（22.23.2）`）；
- 在执行「安装」「更新」「启动」之前，框架会调用 `lib/dependency.sh` 检查依赖语言：
  - 已安装：直接继续；
  - 未安装：提示并询问（默认「是」），确认后**直接调用语言模块的安装动作**，安装过程、源选择与版本选择都由该语言模块负责；
  - 语言模块的安装动作是幂等的：`current` 版本可用时立即提示「已安装且可用」并返回，不会重新拉起安装向导（要重装同一版本请用 `LINUXAPP_LANG_FORCE_INSTALL=1`）；
- 本模块在「安装/更新/启动/回滚/修复服务文件」内部也会再检查一次（幂等），所以直接执行
  `sh modules/software/deepseek-harness/module.sh install` 也能触发联动；
- 联动之外，模块还会校验 Node.js 主版本不低于 20，过低会提示到语言模块执行「更新」。

自动化开关：

| 变量 | 作用 |
| --- | --- |
| `LINUXAPP_APP_AUTO_DEPS=1` | 缺依赖语言时自动安装，不询问 |
| `LINUXAPP_APP_AUTO_DEPS=0` | 只提示不安装，依赖未满足时中止本次操作 |

## 八、卸载

选择「卸载」后：

1. `systemctl disable --now` 停止并取消开机自启；
2. 删除服务文件并 `daemon-reload`；
3. 删除命令入口 `/usr/local/bin/linuxapp-dsh`（按标记精确删除）；
4. 询问是否删除版本目录（默认「是」）与 `DSH_HOME` 数据目录（默认「否」，里面是会话与凭证）；
5. 删除模块状态文件。

设置 `LINUXAPP_DSH_PURGE=1` 可跳过询问，直接删除应用目录与 `DSH_HOME`。

## 九、命令行用法（自动化）

```sh
# 状态与依赖声明
sh modules/software/deepseek-harness/module.sh status
sh modules/software/deepseek-harness/module.sh requires
sh modules/software/deepseek-harness/module.sh extras

# 查看当前访问地址（含 token，隐藏模式下也完整显示）
sh modules/software/deepseek-harness/module.sh url

# 状态里隐藏 token
LINUXAPP_DSH_HIDE_TOKEN=1 sh modules/software/deepseek-harness/module.sh status

# 安装最新版本（国内 npm 镜像，自动确认）
LINUXAPP_DSH_NPM_SOURCE=mirror LINUXAPP_DSH_YES=1 \
  sh modules/software/deepseek-harness/module.sh install

# 安装指定版本，并指定端口
LINUXAPP_DSH_VERSION=0.1.5-rc.1 LINUXAPP_DSH_PORT=3080 \
  LINUXAPP_DSH_YES=1 sh modules/software/deepseek-harness/module.sh install

# 更新到最新版本（失败不会自动回滚）
LINUXAPP_DSH_NPM_SOURCE=mirror LINUXAPP_DSH_YES=1 \
  sh modules/software/deepseek-harness/module.sh update

# 回滚
LINUXAPP_DSH_YES=1 sh modules/software/deepseek-harness/module.sh rollback

# 卸载并清理全部数据
LINUXAPP_DSH_YES=1 LINUXAPP_DSH_PURGE=1 sh modules/software/deepseek-harness/module.sh uninstall
```

`status` 只在标准输出写一行 `状态|版本|说明`（访问地址含 token，直接写在说明里）；`requires` 输出空格分隔的语言键；`extras` 每行输出 `动作键|中文名`。

## 十、环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `LINUXAPP_DSH_VERSION` | 空（=最新） | 安装/更新的目标版本号或标签（`latest`、`next`、`0.1.5-rc.1`） |
| `LINUXAPP_DSH_NPM_SOURCE` | 交互询问 | `mirror` 或 `official`；非交互环境建议显式指定 |
| `LINUXAPP_DSH_NPM_REGISTRY` | 空 | 自定义 npm registry（设置后覆盖上面两项） |
| `LINUXAPP_DSH_PORT` | `3080` | 监听端口 |
| `LINUXAPP_DSH_HOST` | —— | **已废弃**：监听地址固定为 `127.0.0.1`，设置其它值会被忽略并提示（见第十一节） |
| `LINUXAPP_DSH_TRUSTED_HOST` | —— | **已废弃**：仅本机访问不需要可信主机白名单，设置后会被清除并提示 |
| `LINUXAPP_DSH_HOME` | `~/.dsh` | DSH 数据目录 |
| `LINUXAPP_DSH_WORKSPACE` | `~/` | 服务的 `WorkingDirectory`，也是会话默认工作区 |
| `LINUXAPP_DSH_NODE_BIN` | 语言模块的 `nodejs/current/bin` | Node.js 运行时目录 |
| `LINUXAPP_DSH_NPM_BIN` | `<Node 目录>/npm` | npm 可执行文件 |
| `LINUXAPP_DSH_WAIT` | `30` | 启动后等待进入运行状态的秒数 |
| `LINUXAPP_DSH_SETTLE` | `3` | 判定「启动成功」前的稳定观察秒数：进程刚起来就崩溃时 `is-active` 会短暂返回 active，因此启动后需再等这段时间，并要求没有发生自动重启 |
| `LINUXAPP_DSH_URL_TRIES` | `6` | 启动成功后从日志读取访问地址的重试次数（每次间隔 2 秒，取不到不影响启动判定） |
| `LINUXAPP_DSH_YES` | `0` | `1` 表示自动确认所有询问（兼容 `LINUXAPP_LANG_YES`） |
| `LINUXAPP_DSH_KEEP_HISTORY` | `0` | `1` 表示启动成功后保留历史版本 |
| `LINUXAPP_DSH_HIDE_TOKEN` | `0` | `1` 表示状态里隐藏访问地址的 token（框架 `--hide-secrets` 同样生效）；「查看访问地址」始终完整显示 |
| `LINUXAPP_DSH_PURGE` | `0` | `1` 表示卸载时一并删除版本目录与 `DSH_HOME` |
| `LINUXAPP_DSH_ROOT` | `/opt/linuxapp/apps/deepseek-harness` | 应用根目录 |
| `LINUXAPP_DSH_UNIT_DIR` | `/etc/systemd/system` | 服务单元目录（测试用） |
| `LINUXAPP_DSH_SYSTEMCTL` / `LINUXAPP_DSH_JOURNALCTL` | `systemctl` / `journalctl` | 命令覆盖（测试用） |
| `LINUXAPP_DSH_WRAPPER` | `/usr/local/bin/linuxapp-dsh` | 命令入口路径 |
| `LINUXAPP_APP_AUTO_DEPS` | 空（交互询问） | 框架联动：`1` 自动装依赖语言、`0` 只提示 |

## 十一、安全说明

- 监听地址**固定为 `127.0.0.1`**，不提供选择：上游 `dsh web` 绑定非回环地址（内网 IP 或 `0.0.0.0`）都会启动失败，所以模块只允许本机访问，不给出「开放内网」的开关。
- 访问地址里带有**进程 token**，默认在状态里明文显示（否则无法直接打开界面）：这意味着不要把菜单输出重定向到共享日志或公开位置。需要隐藏时用 `./main.sh --hide-secrets` 或 `LINUXAPP_DSH_HIDE_TOKEN=1`；token 每次启动都会变化，泄露影响面仅限该次进程。
- 需要从别的机器访问时，请用 SSH 端口转发（例如 `ssh -L 3080:127.0.0.1:3080 <主机>`）后再打开 `http://127.0.0.1:3080/?token=...`，不要试图改监听地址（改了一定起不来）。
- 服务以 root 运行；如果你希望降权运行，请在服务文件里自行调整 `User=`（模块当前按需求只支持系统级 root 服务）。

## 十二、常见问题

**1. 更新后服务起不来怎么办？**
先「查看最近日志」。若是插件不兼容，用 `/usr/local/bin/linuxapp-dsh plugin --profile web list` 查看并按需 `remove`，再选「启动」；也可以直接选「回滚到上一版本」。模块不会自动回滚，状态会一直是「异常」直到启动成功。

**2. 为什么更新后旧版本目录消失了？**
这是按设计要求：应用启动成功后会删除历史版本与回滚点，稳态只保留当前版本。需要保留旧版本时用 `LINUXAPP_DSH_KEEP_HISTORY=1`。

**3. 状态显示「异常」但没有回滚项？**
说明没有可回滚的历史版本（例如首次安装就没启动成功）。可修复后「启动」、「修复服务文件」，或卸载重装。

**4. 安装时提示找不到 Node.js**
在「应用管理 → 语言模块 → Node.js 运行时」安装 20 或更高版本；框架联动时也会帮你自动安装。

**5. 端口被占用**
安装时会提示并允许换端口；非交互场景用 `LINUXAPP_DSH_PORT` 指定。

**6. 断网时还能更新吗？**
不能联网时无法获取新版本；模块会改用 `cache/dsh-registry.json` 缓存并提示「可能不是最新」。已安装版本的启动、停止、状态查询、回滚都不需要联网。

**7. 我想手动运行一次（不使用服务）**
可以直接执行服务文件里的命令，或使用命令入口：

```sh
/usr/local/bin/linuxapp-dsh web --host 127.0.0.1 --port 3081 --no-open
```

**8. 服务文件被别的东西覆盖了**
选择「修复服务文件」：按状态里记录的版本、端口与 Node.js 目录重建单元（监听地址固定写 `127.0.0.1`），并重新设置开机自启。

**9. 为什么不能改监听地址？**
上游 `dsh web` 只接受本机回环地址，指定内网 IP 或 `0.0.0.0` 都会直接启动失败，所以模块把地址固定为 `127.0.0.1`：
安装时不再询问地址，`LINUXAPP_DSH_HOST` 也不再生效（设置后会在写服务文件时提示并忽略），老的 `trusted_host` 配置会被自动清除。
老版本留下过内网地址的机器，执行一次「更新」「回滚」或「修复服务文件」即可把服务文件改回 `127.0.0.1`（会打印中文提示）。需要远程访问请用 SSH 端口转发。

**10. 状态里的访问地址打不开，或者 token 不对了？**
token 是**进程级**的：服务如果在模块之外被重启过（例如手工 `systemctl restart`），状态里可能还是上一次的 token。
选择「查看访问地址」重新读取日志里最新的一条并刷新状态即可；临时不想看到 token 就用 `./main.sh --hide-secrets`。

**11. 菜单里怎么看不到 token？**
先确认没有加 `--hide-secrets`、也没有设置 `LINUXAPP_DSH_HIDE_TOKEN=1`；隐藏时状态里只显示不含 token 的基准地址。
另外「安装/启动/更新成功」时的提示和「查看访问地址」都是显式输出，即使隐藏 token 也会完整打印地址。

# Last updated: 2026-09-12 17:52
