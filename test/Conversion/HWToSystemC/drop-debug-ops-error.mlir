// RUN: circt-opt --convert-hw-to-systemc="drop-debug-ops=false" %s --verify-diagnostics

// With `drop-debug-ops=false` the `sim` debug/control ops are errors instead of
// being dropped, so a design whose behavior depends on them cannot silently
// lose it.  The diagnostic names the offending operation instead of reporting a
// `systemc.convert` result-type failure.

hw.module @debug_ops_kept(in %clk: i1, in %reset: i1, in %next: i8,
                          out value: i8) {
  %clock = seq.to_clock %clk
  %zero = hw.constant 0 : i8
  %true = hw.constant true
  %value = seq.compreg name "value" %next, %clock reset %reset, %zero : i8
  // expected-error@+1 {{the generated SystemC model does not run CIRCT's `sim` runtime}}
  sim.clocked_terminate %clock, %true, success, quiet
  hw.output %value : i8
}
