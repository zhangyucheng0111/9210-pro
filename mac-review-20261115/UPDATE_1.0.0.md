# 9210 Pro Control 1.0（v1.0.0，构建 37）

- 单击文件夹标题会高亮选中；左侧箭头和双击标题用于展开、折叠，拖动标题仍可排序。
- 选中文件夹时，侧栏「更多」显示重命名和移除文件夹。中间继续显示原来打开的程序。
- 保留一级文件夹、程序多选拖放和自动保存；应用升级沿用现有工作区。

独立工作区验证了单击高亮、展开折叠后保留选择、文件夹菜单、移动文件夹后保留高亮，以及多选程序拖入。核心回归 8,421 项、程序交互模型 106 项通过，验证期间未连接工作站。

2026-11-19 生成两份 ZIP，最低 macOS 14.0：

| 芯片 | 分发包 | 校验 |
|---|---|---|
| M 芯片（arm64） | [M 芯片版](../Mac/releases/9210-Pro-Control-1.0.0-Mac-AppleSilicon.zip) | [SHA-256](../Mac/releases/9210-Pro-Control-1.0.0-Mac-AppleSilicon.sha256) · [验证报告](../Mac/releases/verification-1.0.0-Mac-AppleSilicon.json) |
| Intel（x86_64） | [Intel 版](../Mac/releases/9210-Pro-Control-1.0.0-Mac-Intel.zip) | [SHA-256](../Mac/releases/9210-Pro-Control-1.0.0-Mac-Intel.sha256) · [验证报告](../Mac/releases/verification-1.0.0-Mac-Intel.json) |

两份 ZIP 均通过解压后签名、架构、资源与校验和检查。应用使用本地签名，尚未做 Apple 公证。Intel 实机和 macOS 14/15 运行兼容性未实测。包内附安装与迁移说明，不含用户自定义工作区。
