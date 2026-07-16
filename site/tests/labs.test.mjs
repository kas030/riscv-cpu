import assert from "node:assert/strict";
import test from "node:test";
import { analyzePair, instructionPresets, resolveControl, selectForward, selectLoad } from "../app/lib/labs.mjs";

test("dual issue accepts independent ALU instructions and rejects RAW", () => {
  assert.equal(analyzePair(instructionPresets.addi_x5, instructionPresets.xor_x7).allowed, true);
  const raw = analyzePair(instructionPresets.addi_x5, instructionPresets.add_x6_x5);
  assert.equal(raw.allowed, false);
  assert.match(raw.reasons[0], /RAW/);
});

test("current pairing model preserves younger-lane WAW semantics", () => {
  const waw = analyzePair(instructionPresets.addi_x5, instructionPresets.li_x5);
  assert.equal(waw.allowed, true);
  assert.equal(waw.waw, true);
  assert.match(waw.note, /槽 1/);
});

test("forwarding chooses newest stage then younger lane", () => {
  assert.equal(selectForward(5, {
    MEM1_0: { valid: true, rd: 5 },
    MEM1_S1: { valid: true, rd: 5 },
    MEM2_S1: { valid: true, rd: 5 },
    WB_0: { valid: true, rd: 5 },
  }), "MEM1_S1");
  assert.equal(selectForward(6, { MEM1_0: { valid: true, rd: 7 } }), "REGFILE");
});

test("load lane selection and extension match RV32 little endian semantics", () => {
  const word = 0x80ff7f01;
  assert.equal(selectLoad(word, 0, "byte", false), 0x00000001);
  assert.equal(selectLoad(word, 1, "byte", false), 0x0000007f);
  assert.equal(selectLoad(word, 2, "byte", false), 0xffffffff);
  assert.equal(selectLoad(word, 3, "byte", true), 0x00000080);
  assert.equal(selectLoad(word, 2, "half", false), 0xffff80ff);
  assert.equal(selectLoad(word, 0, "word", false), word >>> 0);
});

test("control priority holds M operations and preserves pending redirect", () => {
  const busy = resolveControl({ redirectPending: false, exBusy: true, loadHazard: true });
  assert.equal(busy.stallFront, true);
  assert.equal(busy.flushIdEx, false);
  assert.match(busy.action, /M 单元/);
  const redirect = resolveControl({ redirectPending: true, exBusy: true, loadHazard: false });
  assert.equal(redirect.flushIfId, true);
  assert.match(redirect.action, /保持已锁存重定向/);
});
