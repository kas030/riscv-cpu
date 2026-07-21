# RISC-V CPU 交互式教学网站

这是 `rtl/` 当前实现对应的中文课程站点，内容覆盖双槽顺序发射流水线、预测、译码、RV32M、CSR/trap、同步 BRAM、L0、前递和冒险控制。

站点只覆盖 CPU 核及其外部取指、数据接口契约，不展开板级外设、Vivado IP 或 SoC 集成。它只在本机运行，不需要数据库、对象存储或线上部署。

## 环境要求

- Node.js 22.13.0 或更高版本
- Node.js 自带的 npm

可先检查当前版本：

```powershell
node --version
npm --version
```

## 安装依赖

在仓库根目录运行：

```powershell
cd site
npm ci --include=optional
```

后续命令都在 `site/` 目录内执行。

`node_modules/` 包含操作系统相关的原生模块，不能在 Linux 与 Windows 之间
直接复制或复用。切换操作系统后应在目标系统重新执行上述安装命令。

## 开发模式访问

启动带热更新的本地开发服务器：

```powershell
npm run dev
```

启动成功后，用浏览器打开终端中 `Local` 一行给出的地址，通常是：

```text
http://localhost:3000/
```

如果 3000 端口已被占用，开发服务器会改用其他端口，应以终端实际显示的地址为准。按 `Ctrl+C` 停止服务器。

## 生产构建与本地访问

生成生产版本：

```powershell
npm run build
```

构建产物位于 `site/dist/`。构建成功后启动本地生产服务器：

```powershell
npm run start
```

然后打开终端给出的本地地址，通常仍为 `http://localhost:3000/`。`npm run build` 只生成产物，不会自行启动可访问的服务器。

`npm run start` 使用构建产物自带的 Cloudflare 本地运行时，因此 Linux 和
Windows 都会正确提供 `/assets/` 下的样式与脚本。可用 `PORT` 环境变量修改端口。

`npm run dev` 与 `npm run build` 都会先同步 RTL 代码片段和 CPU 可视化数据。
构建会校验 graph/trace JSON schema、当前 RTL 摘要、九个场景的 PASS/参考对拍
状态，以及 53 条指令与分支方向、地址 lane、冒险、L0、RV32M 边界等覆盖矩阵；
源码标记缺失、trace 过期或场景不完整时直接失败。

交互式 CPU 原理图位于 `/simulator`。页面首次只加载 graph、场景索引和首个
128-cycle chunk，播放或跳转时才按需取得后续 chunk。执行值全部来自
CPU-only Verilator trace，前端只负责重建、筛选和格式化。

新增模块需要辅助排布时可运行 `npm run layout:visualizer` 获取 ELK 分层布局建议；
该命令只输出候选坐标，人工检查后才写入版本化 `manifest.layouts`，因此构建结果
不会随自动布局算法漂移。

## 验证

执行生产构建和全部自动化测试：

```powershell
npm test
```

单独检查代码规范：

```powershell
npm run lint
```

安装 Playwright Chromium 后可执行四组基准截图，以及逐拍、分块、场景切换、
搜索、键盘、减少动态效果和长 RV32M trace 响应性等浏览器集成测试：

```powershell
node node_modules/playwright/cli.js install chromium
npm run test:visual
```

RTL 或场景修改后，先从仓库根目录运行
`./sim_cpu_only/run_all_visual_traces.sh`，再执行站点测试。视觉变更经过人工检查后
使用 `npm run test:visual:update` 更新基准图。
