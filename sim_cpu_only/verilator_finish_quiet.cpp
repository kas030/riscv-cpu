#include "verilated.h"

void vl_finish(const char*, int, const char*) {
    Verilated::threadContextp()->gotFinish(true);
}
