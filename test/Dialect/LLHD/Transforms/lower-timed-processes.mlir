// RUN: circt-opt --llhd-lower-timed-processes %s | FileCheck %s
// RUN: circt-opt --llhd-lower-timed-processes --canonicalize %s | FileCheck %s --check-prefix=CANON

// CHECK-LABEL: hw.module @counter
hw.module @counter(in %clk : i1, out count : i2) {
  %c0_i2 = hw.constant 0 : i2
  %c1_i2 = hw.constant 1 : i2
  %true = hw.constant true
  %t = llhd.constant_time <1ns, 0d, 0e>
  // CHECK: %[[TO_CLOCK:.+]] = seq.to_clock %clk
  // CHECK: %[[REG:.+]] = seq.compreg %{{.+}}, %[[TO_CLOCK]] : i2
  // CHECK: hw.output %[[REG]] : i2
  %sig = llhd.sig %c0_i2 : i2
  %0:1 = llhd.process -> i2 {
    cf.br ^bb1(%c0_i2 : i2)
  ^bb1(%state: i2):
    llhd.wait yield (%state : i2), (%clk : i1), ^bb2(%clk : i1)
  ^bb2(%prev_clk: i1):
    %not_prev = comb.xor %prev_clk, %true : i1
    %edge = comb.and %not_prev, %clk : i1
    cf.cond_br %edge, ^bb3, ^bb1(%c0_i2 : i2)
  ^bb3:
    %inc = comb.add bin %state, %c1_i2 : i2
    cf.br ^bb1(%inc : i2)
  }
  llhd.drv %sig, %0 after %t : i2
  %1 = llhd.prb %sig : i2
  hw.output %1 : i2
}

// CHECK-LABEL: hw.module @conditional_comb
// CHECK-NOT: llhd.combinational
// CHECK-NOT: llhd.sig
// CHECK-NOT: llhd.drv
// CHECK-NOT: llhd.prb
hw.module @conditional_comb(in %select : i1, in %a : i8, in %b : i8,
                            out value : i8) {
  %zero = hw.constant 0 : i8
  %time = llhd.constant_time <0ns, 0d, 1e>
  %signal = llhd.sig %zero : i8
  %result = llhd.combinational -> i8 {
    cf.cond_br %select, ^bb1, ^bb2
  ^bb1:
    llhd.drv %signal, %a after %time : i8
    cf.br ^bb3(%a : i8)
  ^bb2:
    llhd.drv %signal, %b after %time : i8
    cf.br ^bb3(%b : i8)
  ^bb3(%selected : i8):
    llhd.yield %selected : i8
  }
  %observed = llhd.prb %signal : i8
  // CHECK: comb.mux
  // CHECK: hw.output
  hw.output %observed : i8
}

// A path that does not update state must feed back the current register value,
// while the active path must retain its computed next value.
// CHECK-LABEL: hw.module @hold_counter
// CHECK: %[[REG:.+]] = seq.compreg %[[NEXT:.+]], %{{.+}} : i2
// CHECK: %[[INC:.+]] = comb.add %[[REG]], {{.+}} : i2
// CHECK: %[[NEXT]] = comb.mux {{.+}}, %[[INC]], %[[REG]] : i2
// CHECK: hw.output %[[REG]] : i2
hw.module @hold_counter(in %clk : i1, in %enable : i1, out count : i2) {
  %zero = hw.constant 0 : i2
  %one = hw.constant 1 : i2
  %true = hw.constant true
  %time = llhd.constant_time <0ns, 1d, 0e>
  %signal = llhd.sig %zero : i2
  %0:1 = llhd.process -> i2 {
    cf.br ^bb1(%zero : i2)
  ^bb1(%state : i2):
    llhd.wait yield (%state : i2), (%clk : i1), ^bb2(%clk : i1)
  ^bb2(%previousClock : i1):
    %notPrevious = comb.xor %previousClock, %true : i1
    %edge = comb.and %notPrevious, %clk : i1
    %update = comb.and %edge, %enable : i1
    cf.cond_br %update, ^bb3, ^bb1(%state : i2)
  ^bb3:
    %incremented = comb.add %state, %one : i2
    cf.br ^bb1(%incremented : i2)
  }
  llhd.drv %signal, %0 after %time : i2
  %observed = llhd.prb %signal : i2
  hw.output %observed : i2
}

// The destination operands of `llhd.wait` are filled in by `llhd-mem2reg` while
// walking a liveness set, so their order relative to `observed` carries no
// contract and may differ from the sensitivity-list order that produced
// `observed`.  The lowering must therefore not pair the two lists positionally.
//
// This module is `@hold_counter` with the destination operands reversed.  It
// must lower to the same counter.
//
// Before the fix the previous-value inversion was skipped for both operands,
// which turned the clock-edge term `!previous & current` into `!current &
// current`.  Canonicalization then folds the whole process into a frozen
// register, and every sequential update is silently dropped.
// CANON-LABEL: hw.module @hold_counter_reversed_wait_order
// CANON: %[[TO_CLOCK:.+]] = seq.to_clock %clk
// CANON: %[[ENABLE:.+]] = comb.and %clk, %enable : i1
// CANON: %[[REG:.+]] = seq.compreg %[[NEXT:.+]], %[[TO_CLOCK]] : i2
// CANON: %[[INC:.+]] = comb.add %[[REG]], %{{.+}} : i2
// CANON: %[[NEXT]] = comb.mux %[[ENABLE]], %[[INC]], %[[REG]] : i2
// CANON: hw.output %[[REG]] : i2
hw.module @hold_counter_reversed_wait_order(in %clk : i1, in %reset : i1,
                                            in %enable : i1, out count : i2) {
  %zero = hw.constant 0 : i2
  %one = hw.constant 1 : i2
  %true = hw.constant true
  %time = llhd.constant_time <0ns, 1d, 0e>
  %signal = llhd.sig %zero : i2
  %0:1 = llhd.process -> i2 {
    cf.br ^bb1(%zero : i2)
  ^bb1(%state : i2):
    // Note the reversed destination operands.
    llhd.wait yield (%state : i2), (%clk, %reset : i1, i1), ^bb2(%reset, %clk : i1, i1)
  ^bb2(%previousReset : i1, %previousClock : i1):
    %notPrevious = comb.xor %previousClock, %true : i1
    %edge = comb.and %notPrevious, %clk : i1
    %update = comb.and %edge, %enable : i1
    cf.cond_br %update, ^bb3, ^bb1(%state : i2)
  ^bb3:
    %incremented = comb.add %state, %one : i2
    cf.br ^bb1(%incremented : i2)
  }
  llhd.drv %signal, %0 after %time : i2
  %observed = llhd.prb %signal : i2
  hw.output %observed : i2
}

// A conditional branch is allowed to use the same block for both destinations:
//   cf.cond_br %c, ^bb(%a), ^bb(%b)
// That is a single predecessor with *two* edges, and the two arms carry
// different operands.  Both edges have to be materialized.  The lowering used
// to report only the true arm, which silently dropped the increment selected on
// the other arm; the counter then held its value, and canonicalization deleted
// the now-dead `comb.add`.  The surviving add after canonicalization is
// therefore the fingerprint of this bug.
// CANON-LABEL: hw.module @branch_same_destination
// CANON: %[[REG:.+]] = seq.compreg %{{.+}}, %{{.+}} : i2
// CANON: %[[INC:.+]] = comb.add %[[REG]], %{{.+}} : i2
// CANON: hw.output %[[REG]] : i2
hw.module @branch_same_destination(in %clk : i1, in %reset : i1,
                                   out count : i2) {
  %zero = hw.constant 0 : i2
  %one = hw.constant 1 : i2
  %true = hw.constant true
  %time = llhd.constant_time <0ns, 1d, 0e>
  %signal = llhd.sig %zero : i2
  %0:1 = llhd.process -> i2 {
    cf.br ^bb1(%zero : i2)
  ^bb1(%state : i2):
    llhd.wait yield (%state : i2), (%clk : i1), ^bb2(%clk : i1)
  ^bb2(%previousClock : i1):
    %notPrevious = comb.xor %previousClock, %true : i1
    %edge = comb.and %notPrevious, %clk : i1
    cf.cond_br %edge, ^bb3, ^bb1(%state : i2)
  ^bb3:
    %incremented = comb.add %state, %one : i2
    // Same successor on both arms, with different operands.
    cf.cond_br %reset, ^bb4(%state : i2), ^bb4(%incremented : i2)
  ^bb4(%next : i2):
    cf.br ^bb1(%next : i2)
  }
  llhd.drv %signal, %0 after %time : i2
  %observed = llhd.prb %signal : i2
  hw.output %observed : i2
}
