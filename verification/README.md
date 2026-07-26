# CPU Verification

此目录是当前 CPU 的可信验证入口，完全独立于已知有误的 `vivado/tests/`。

## 本地测试

```sh
cd verification
make check
make run TEST=rv32i
make regression
```

本地测试包括：

- `rv32i`：37 条 RV32I、寄存器边界、分支/跳转和对齐 load/store；
- `rv32m`：八条 RV32M、除零、溢出和多周期相关；
- `zicsr_trap`：六种 CSR 指令、五个 CSR、`ecall/mret`；
- `pipeline`：双槽、前递、load-use、flush、RV32M busy、CRC 融合和 `orc.b`；
- `memory`：BRAM 边界、子字访问、L0、MMIO 和 COUNTER；
- `perf_micro`：只展示性能计数的固定混合负载。

构建会检查运行地址、IROM/BRAM 容量并反汇编拒绝能力边界外指令。生成物和 JSON
结果位于 `verification/build/`，不提交 Git。

## 固定的开源测试

```sh
cd verification
make fetch-open-source
make verify-open-source
make build-open-source
make run-open-source
```

`upstream.lock.json` 固定完整 commit。当前实际启用 `riscv-tests` 的 45 个
RV32UI/RV32UM 白名单用例；ACT4 和 Embench 在专用适配及逐项能力审查完成前保持
禁用。上游目录位于被忽略的 `verification/third_party/`。

## 竞赛镜像

```sh
cd verification
make competition
```

该目标原样运行 `sim/coe/mext/irom-v2.coe` 与 `dram.coe`，LED
`0x078B7323` 为正确完成，结果写入 `build/irom-v2-result.json`。性能指标只展示，
不参与正确性门禁。

实测结果、性能数据和已发现问题统一记录在
[`docs/tests/cpu_test_report.md`](../docs/tests/cpu_test_report.md)，不与测试计划或使用说明混写。
