// RUN: circt-opt -pass-pipeline='builtin.module(calyx.component(calyx-compile-repeat))' --split-input-file %s | FileCheck %s --implicit-check-not="calyx.repeat"

// CHECK-LABEL: calyx.component @main(
module attributes {calyx.entrypoint = "main"} {
  calyx.component @main(%go: i1 {go}, %clk: i1 {clk}, %reset: i1 {reset}) -> (%done: i1 {done}) {
    %true = hw.constant true
    calyx.wires {
      calyx.group @B {
        calyx.group_done %true : i1
      }
    }
    calyx.control {
      calyx.seq {
        calyx.repeat 4 {
          calyx.seq {
            calyx.enable @B
          }
        }
      }
    }
  }
}

// CHECK: calyx.std_lt @repeat_lt
// CHECK: calyx.std_add @repeat_add
// CHECK: calyx.register @repeat_cond_reg
// CHECK: calyx.register @repeat_counter_reg
// CHECK: calyx.wires {
// CHECK: calyx.group @B
// CHECK: calyx.group @repeat_init
// CHECK: calyx.group @repeat_incr
// CHECK: calyx.group @repeat_cond
// CHECK: calyx.control {
// CHECK: calyx.enable @repeat_init
// CHECK: calyx.enable @repeat_cond
// CHECK: calyx.while %repeat_cond_reg.out {
// CHECK: calyx.enable @B
// CHECK: calyx.enable @repeat_incr
// CHECK: calyx.enable @repeat_cond

// -----

// A repeat with its body directly under `calyx.control` (single-op region).

// CHECK-LABEL: calyx.component @one(
module attributes {calyx.entrypoint = "one"} {
  calyx.component @one(%go: i1 {go}, %clk: i1 {clk}, %reset: i1 {reset}) -> (%done: i1 {done}) {
    %true = hw.constant true
    calyx.wires {
      calyx.group @B {
        calyx.group_done %true : i1
      }
    }
    calyx.control {
      calyx.repeat 1 {
        calyx.enable @B
      }
    }
  }
}

// CHECK: calyx.register @repeat_counter_reg
// CHECK: calyx.while %repeat_cond_reg.out {
// CHECK: calyx.enable @repeat_init
// CHECK: calyx.enable @repeat_incr
// CHECK: calyx.enable @repeat_cond

// -----

// A zero-trip repeat disappears entirely.

// CHECK-LABEL: calyx.component @zero(
module attributes {calyx.entrypoint = "zero"} {
  calyx.component @zero(%go: i1 {go}, %clk: i1 {clk}, %reset: i1 {reset}) -> (%done: i1 {done}) {
    %true = hw.constant true
    calyx.wires {
      calyx.group @B {
        calyx.group_done %true : i1
      }
    }
    calyx.control {
      calyx.repeat 0 {
        calyx.enable @B
      }
    }
  }
}

// CHECK: calyx.control {
// CHECK-NOT: calyx.while

// -----

// Nested repeats each get their own counter and while loop.

// CHECK-LABEL: calyx.component @nested(
module attributes {calyx.entrypoint = "nested"} {
  calyx.component @nested(%go: i1 {go}, %clk: i1 {clk}, %reset: i1 {reset}) -> (%done: i1 {done}) {
    %true = hw.constant true
    calyx.wires {
      calyx.group @B {
        calyx.group_done %true : i1
      }
    }
    calyx.control {
      calyx.repeat 2 {
        calyx.seq {
          calyx.enable @B
          calyx.repeat 3 {
            calyx.enable @B
          }
        }
      }
    }
  }
}

// CHECK: calyx.enable @repeat_init
// CHECK: calyx.enable @repeat_cond
// CHECK: calyx.while %repeat_cond_reg.out {
// CHECK: calyx.enable @B
// CHECK: calyx.enable @repeat_1_init
// CHECK: calyx.enable @repeat_1_cond
// CHECK: calyx.while %repeat_1_cond_reg.out {
// CHECK: calyx.enable @B
// CHECK: calyx.enable @repeat_1_incr
// CHECK: calyx.enable @repeat_1_cond
// CHECK: calyx.enable @repeat_incr
// CHECK: calyx.enable @repeat_cond
