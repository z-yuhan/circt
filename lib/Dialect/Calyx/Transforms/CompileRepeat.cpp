//===- CompileRepeat.cpp - Lower calyx.repeat to a while loop ---*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Lowers `calyx.repeat` into an equivalent `calyx.while` loop driven by a
// dedicated trip counter. CalyxToFSM supports `while` control but not
// `repeat`, so designs produced from `scf.for` (which SCFToCalyx emits as
// `repeat`) cannot be compiled to RTL without this lowering.
//
// Every `repeat N { body }` becomes:
//
//   seq {
//     enable @<u>_init                 // counter = 0
//     enable @<u>_cond                 // cond = (counter < N)
//     while %<u>_cond_reg.out {
//       seq { body; enable @<u>_incr; enable @<u>_cond }
//     }
//   }
//
// The condition register is refreshed after every iteration, mirroring the
// group/register discipline already used by SCFToCalyx and RemoveCombGroups,
// so that the FSM's transition guards always sample a stable register value.
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Calyx/CalyxHelpers.h"
#include "circt/Dialect/Calyx/CalyxLoweringUtils.h"
#include "circt/Dialect/Calyx/CalyxOps.h"
#include "circt/Dialect/Calyx/CalyxPasses.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinTypes.h"
#include "llvm/ADT/StringSet.h"

namespace circt {
namespace calyx {
#define GEN_PASS_DEF_COMPILEREPEAT
#include "circt/Dialect/Calyx/CalyxPasses.h.inc"
} // namespace calyx
} // namespace circt

using namespace mlir;
using namespace circt;
using namespace circt::calyx;

namespace {

/// Lowers every repeat operation nested in a single component.
///
/// Rewriting an outer repeat moves (but does not erase) any nested repeats
/// along with the rest of its body, so handles collected up-front remain
/// valid for the whole run.
class RepeatLowering {
public:
  RepeatLowering(ComponentOp component, OpBuilder &builder)
      : component(component), builder(builder) {
    // Seed the set of used symbol names with everything already in the
    // component so generated names never collide with existing ones.
    component.walk([&](Operation *op) {
      if (auto sym = op->getAttrOfType<StringAttr>("sym_name"))
        usedNames.insert(sym.getValue());
    });
  }

  void run() {
    SmallVector<RepeatOp> repeats;
    component.walk([&](RepeatOp op) { repeats.push_back(op); });
    for (RepeatOp op : repeats)
      lower(op);
  }

private:
  /// Returns all symbol names derived from a candidate `base`.
  static SmallVector<std::string> derivedNames(StringRef base) {
    std::string b = base.str();
    return {b,
            b + "_counter_reg",
            b + "_cond_reg",
            b + "_add",
            b + "_lt",
            b + "_init",
            b + "_incr",
            b + "_cond"};
  }

  /// Picks a fresh base name for this repeat's cells and groups and reserves
  /// every derived symbol name.
  std::string reserveNames() {
    std::string base;
    do {
      base = repeatIndex == 0 ? "repeat"
                              : "repeat_" + std::to_string(repeatIndex);
      ++repeatIndex;
      bool collides = false;
      for (const std::string &name : derivedNames(base))
        collides |= usedNames.contains(name);
      if (!collides)
        break;
    } while (true);
    for (const std::string &name : derivedNames(base))
      usedNames.insert(name);
    return base;
  }

  void lower(RepeatOp op) {
    uint32_t count = op.getCount();
    if (count == 0) {
      op.erase();
      return;
    }

    Location loc = op.getLoc();
    MLIRContext *ctx = builder.getContext();
    // The counter is incremented after the last iteration, so it must be wide
    // enough to hold `count` itself.
    unsigned width = 1;
    while ((uint64_t(1) << width) <= uint64_t(count))
      ++width;
    auto intType = IntegerType::get(ctx, width);
    auto i1Type = builder.getI1Type();
    std::string u = reserveNames();

    // Datapath cells.
    auto counterReg = createRegister(loc, builder, component, width,
                                     u + "_counter");
    auto condReg = createRegister(loc, builder, component, 1, u + "_cond");
    auto zero = createConstant(loc, builder, component, width, 0);
    auto one = createConstant(loc, builder, component, width, 1);
    auto bound = createConstant(loc, builder, component, width, count);
    auto trueConst = createConstant(loc, builder, component, 1, 1);

    calyx::AddLibOp adder;
    calyx::LtLibOp compare;
    {
      OpBuilder::InsertionGuard guard(builder);
      builder.setInsertionPointToStart(component.getBodyBlock());
      SmallVector<Type> adderTypes{intType, intType, intType};
      adder = calyx::AddLibOp::create(builder, loc, u + "_add", adderTypes);
      SmallVector<Type> compareTypes{intType, intType, i1Type};
      compare = calyx::LtLibOp::create(builder, loc, u + "_lt", compareTypes);
    }

    // counter = 0.
    auto initGroup =
        calyx::createGroup<calyx::GroupOp>(builder, component, loc,
                                           u + "_init");
    {
      OpBuilder::InsertionGuard guard(builder);
      builder.setInsertionPointToEnd(initGroup.getBodyBlock());
      calyx::AssignOp::create(builder, loc, counterReg.getIn(), zero);
      calyx::AssignOp::create(builder, loc, counterReg.getWriteEn(), trueConst);
      calyx::GroupDoneOp::create(builder, loc, counterReg.getDone());
    }

    // counter = counter + 1.
    auto incrGroup =
        calyx::createGroup<calyx::GroupOp>(builder, component, loc,
                                           u + "_incr");
    {
      OpBuilder::InsertionGuard guard(builder);
      builder.setInsertionPointToEnd(incrGroup.getBodyBlock());
      calyx::AssignOp::create(builder, loc, adder.getLeft(),
                              counterReg.getOut());
      calyx::AssignOp::create(builder, loc, adder.getRight(), one);
      calyx::AssignOp::create(builder, loc, counterReg.getIn(),
                              adder.getOut());
      calyx::AssignOp::create(builder, loc, counterReg.getWriteEn(), trueConst);
      calyx::GroupDoneOp::create(builder, loc, counterReg.getDone());
    }

    // cond = counter < count.
    auto condGroup =
        calyx::createGroup<calyx::GroupOp>(builder, component, loc,
                                           u + "_cond");
    {
      OpBuilder::InsertionGuard guard(builder);
      builder.setInsertionPointToEnd(condGroup.getBodyBlock());
      calyx::AssignOp::create(builder, loc, compare.getLeft(),
                              counterReg.getOut());
      calyx::AssignOp::create(builder, loc, compare.getRight(), bound);
      calyx::AssignOp::create(builder, loc, condReg.getIn(), compare.getOut());
      calyx::AssignOp::create(builder, loc, condReg.getWriteEn(), trueConst);
      calyx::GroupDoneOp::create(builder, loc, condReg.getDone());
    }

    // Replace the repeat in-place with the equivalent while loop.
    {
      OpBuilder::InsertionGuard guard(builder);
      builder.setInsertionPoint(op);

      auto outerSeq = calyx::SeqOp::create(builder, loc);
      builder.setInsertionPointToStart(outerSeq.getBodyBlock());
      calyx::EnableOp::create(builder, loc, u + "_init");
      calyx::EnableOp::create(builder, loc, u + "_cond");

      auto whileOp = calyx::WhileOp::create(builder, loc, condReg.getOut(),
                                            FlatSymbolRefAttr());
      builder.setInsertionPointToStart(whileOp.getBodyBlock());
      auto innerSeq = calyx::SeqOp::create(builder, loc);
      auto *innerBody = innerSeq.getBodyBlock();
      for (auto &bodyOp : llvm::make_early_inc_range(*op.getBodyBlock()))
        bodyOp.moveBefore(innerBody, innerBody->end());
      builder.setInsertionPointToEnd(innerBody);
      calyx::EnableOp::create(builder, loc, u + "_incr");
      calyx::EnableOp::create(builder, loc, u + "_cond");

      op.erase();
    }
  }

  ComponentOp component;
  OpBuilder &builder;
  llvm::StringSet<> usedNames;
  unsigned repeatIndex = 0;
};

struct CompileRepeatPass
    : public circt::calyx::impl::CompileRepeatBase<CompileRepeatPass> {
  void runOnOperation() override {
    ComponentOp component = getOperation();
    OpBuilder builder(component.getContext());
    RepeatLowering(component, builder).run();
  }
};

} // end anonymous namespace

std::unique_ptr<mlir::Pass> circt::calyx::createCompileRepeatPass() {
  return std::make_unique<CompileRepeatPass>();
}
