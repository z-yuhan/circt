// RUN: circt-opt --convert-hw-to-systemc %s | FileCheck %s

// The `sim` dialect's debug and control operations are written for CIRCT's own
// `sim` runtime, which the generated SystemC model does not run.  They also take
// a `!seq.clock` operand, a type this conversion maps to `i1`, so a surviving op
// forces an `i1 -> !seq.clock` source materialization that `systemc.convert`
// cannot build, and the pass fails with a message about the conversion's result
// type rather than about the operation that caused it.  With the default
// `drop-debug-ops=true` the pass removes them and warns once per op, so the rest
// of the module still converts.

// CHECK-LABEL: systemc.module @debug_ops
// CHECK-NOT: sim.
// CHECK-NOT: seq.
// CHECK: %[[STATE:.*]] = systemc.signal : !systemc.signal<!systemc.uint<8>>
// CHECK: "systemc.register.write"(%[[STATE]]
hw.module @debug_ops(in %clk: i1, in %reset: i1, in %enable: i1, in %next: i8,
                     out value: i8) {
  %clock = seq.to_clock %clk
  %zero = hw.constant 0 : i8
  %true = hw.constant true
  %value = seq.compreg.ce name "value" %next, %clock, %enable
      reset %reset, %zero : i8
  // A print, a format literal that only it consumes, and the two clocked
  // control ops, all of which have to go.
  %format = sim.fmt.literal "value: "
  sim.print %format on %clock if %true
  sim.clocked_terminate %clock, %true, success, quiet
  sim.clocked_pause %clock, %true, quiet
  hw.output %value : i8
}
