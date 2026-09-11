# LinuxApp

LinuxApp 是一个面向 Linux 的纯 POSIX `sh` 脚本集合，用于统一管理软件、语言环境和常用系统操作。

项目强调轻量、可迁移和可扩展：用户只需要运行 `main.sh`，即可进入交互式菜单；模块脚本按照统一生命周期接口工作，并支持在线加载、缓存、离线清单校验和用户级 SSH 登录钩子。

## 项目主页与开源地址

- 项目主页：将仓库部署到静态服务后访问根目录的 `index.html`
- GitHub：<https://github.com/yxsj245/LinuxApp>

主页先提供“一键使用”主入口，下面的“已有应用”区域当前留空。点击“复制命令”即可将主入口命令粘贴到 Linux 终端；命令中的入口地址会根据当前静态站点地址自动生成。

## 快速开始

```sh
cd LinuxApp
chmod +x main.sh
./main.sh
```

离线模式：

```sh
./main.sh -offline
```

SSH 登录钩子：

```sh
./main.sh --install-ssh-hook
./main.sh --remove-ssh-hook
```

## 当前结构

```text
LinuxApp/
├── index.html                       # 静态项目主页、应用目录与一键命令
├── main.sh                          # 运行入口
├── config/                          # 下载地址与模块清单
├── lib/                             # POSIX sh 公共库
├── modules/                         # 已登记的实际模块
├── docs/                            # 使用文档与模块开发示例
├── AGENTS.md                        # 项目开发规则
└── README.md                        # 项目说明
```

演示软件和演示语言只作为开发示例保存在 `docs/`，不会自动出现在运行菜单。开发真实模块后，将其脚本登记到 `config/modules.list` 即可接入应用管理。

## 静态托管

网页不依赖构建工具或后端接口。部署时请保持 `index.html` 与 `main.sh` 的相对位置不变，例如使用 Nginx、GitHub Pages、对象存储静态网站或其他静态文件服务。

网页已有应用和命令清单位于 `index.html` 内的 `apps` 数组。新增应用或命令后，请同步更新该数组。

## 兼容性

- 目标 Shell：POSIX `sh`
- 已验证：Ubuntu 环境下的 `dash` 与 Bash
- 静态网页：现代桌面和移动浏览器
- 网页复制命令：优先使用 Clipboard API，HTTP 或非安全上下文自动降级到传统复制方案

## 文档

- [使用说明](docs/使用说明.md)
- [演示软件模块开发示例](docs/演示软件模块开发示例.md)
- [演示语言模块开发示例](docs/演示语言模块开发示例.md)

## 许可

当前仓库尚未声明具体开源许可证。正式发布前请在仓库中补充许可证文件和版权信息。
