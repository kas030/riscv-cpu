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
npm ci
```

后续命令都在 `site/` 目录内执行。

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

### Windows 下的已知问题

当前锁定的 `vinext 0.0.50` 在 Windows 上使用 `npm run start` 时存在静态资源路径兼容问题：页面 HTML 可以正常返回，但 `/assets/*.css` 和其他前端资源可能返回 HTTP 404，表现为页面能够打开却没有样式。构建产物本身仍会正常生成在 `dist/client/assets/`，问题发生在生产服务器读取静态资源时。

在该问题修复前，Windows 用户应使用开发服务器访问站点：

```powershell
# 如果 npm run start 仍在运行，先按 Ctrl+C 停止
npm run dev
```

然后访问 `http://localhost:3000/`，端口被占用时以终端显示的实际地址为准。`npm run build` 仍可用于检查生产构建是否成功，但不建议在 Windows 上使用当前版本的 `npm run start` 预览页面。

`npm run dev` 与 `npm run build` 都会先执行 `scripts/sync-rtl-snippets.mjs`，从仓库当前 RTL 重新提取页面中的关键代码。源码标记缺失或重复时命令会直接失败，避免站点静默展示过期片段。

## 验证

执行生产构建和全部自动化测试：

```powershell
npm test
```

单独检查代码规范：

```powershell
npm run lint
```
