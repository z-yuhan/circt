// RUN: circt-opt --canonicalize %s | FileCheck %s

// The "common mux value" fold rewrites `mux(cond, a, mux(cond2, a, b))` into
// `mux(cond|cond2, a, b)`.  When the inner mux feeds its own false operand back
// to itself, the rewrite produces exactly the shape it started from - a mux
// whose condition is an `or` of the inner condition and whose false operand is
// that same inner mux - so the greedy rewriter never reaches a fixpoint: every
// iteration appends one more `comb.or` and the condition grows without bound.
// On the DSC encoder's `dsce_bpvector` this made `--canonicalize` run out of
// memory after ~186 seconds.
//
// The fold must notice that combining the two conditions adds nothing, because
// one of them already contains the other, and leave the mux alone.  Converging
// at all is the property under test here: the checks below only pin the input,
// which has to survive canonicalization unchanged.
// CHECK-LABEL: hw.module @nonconvergent_mux
// CHECK: %[[OR:.+]] = comb.or %c0, %c1 : i1
// CHECK: %[[MUX:.+]] = comb.mux %[[OR]], %a, %[[MUX]] : i8
// CHECK: %[[OUT:.+]] = comb.mux %[[OR]], %a, %[[MUX]] : i8
// CHECK: hw.output %[[OUT]] : i8
hw.module @nonconvergent_mux(in %c0: i1, in %c1: i1, in %a: i8, out out: i8) {
  %o = comb.or %c0, %c1 : i1
  %m = comb.mux %o, %a, %m : i8
  %r = comb.mux %o, %a, %m : i8
  hw.output %r : i8
}
