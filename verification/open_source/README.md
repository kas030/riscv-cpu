# 开源测试接入

本目录记录开源测试的适配边界。上游源码不提交到仓库，版本由
`../upstream.lock.json` 的完整 commit 固定，下载目录 `../third_party/` 被忽略。

## 启用规则

1. 运行 `make fetch-open-source`，再运行 `make verify-open-source`。
2. 只允许 lock 文件中的白名单。新增上游用例必须先审查反汇编、访存地址、
   异常依赖、IROM/BRAM 容量和结束协议。
3. 平台适配只能修改启动、链接布局、signature 导出和 LED 结束动作，不能修改
   上游测试主体或期望结果。
4. `riscv-arch-test` 在 ACT4 UDB、Sail 期望和 `rvmodel_macros.h` 完成审查前保持
   `enabled=false`；不得把“成功编译”等同于认证通过。
5. `embench-iot` 仅作为性能候选。每个 workload 必须独立通过自校验和容量检查，
   之后才能把名称加入显式 allowlist。

`riscv-tests` 的首批白名单只包含 RV32UI 的 37 条基础整数测试和 RV32UM 八条
乘除法测试；明确排除 `fence_i`、非对齐异常、机器异常、S/U 模式和 RV64。
