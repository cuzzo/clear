// FiberStackCheckPass.cpp
//
// A MachineFunctionPass that inserts a call to __morestack at the VERY
// TOP of every function — BEFORE the prologue.
//
// It runs AFTER LLVM's PrologEpilogCodeInserter so the prologue is
// already present, then prepends the check before it via INLINEASM.
//
// Two build modes:
//   1. Plugin (llc --load / --run-pass)
//   2. Standalone tool (fiber-instrument) that runs full codegen
//      with this pass injected — avoids MIR round-trip bugs.
//
// Generated asm (prepended to every instrumented function):
//
//   0:
//       movq  test_stack_limit@gottpoff(%rip), %r11
//       movq  %fs:(%r11), %r11
//       testq %r11, %r11
//       jz    1f
//       cmpq  %r11, %rsp
//       ja    1f
//       callq __morestack
//       jmp   0b
//   1:
//       <prologue follows>

#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/CodeGen/MachineBasicBlock.h"
#include "llvm/CodeGen/MachineFunction.h"
#include "llvm/CodeGen/MachineInstrBuilder.h"
#include "llvm/CodeGen/TargetInstrInfo.h"
#include "llvm/CodeGen/TargetSubtargetInfo.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/InlineAsm.h"
#include "llvm/IR/Module.h"
#include "llvm/Pass.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/TargetParser/Triple.h"

using namespace llvm;

// Uses initial-exec TLS (gottpoff) matching switch.S's convention.
// R11 is caller-saved so clobbering it before the prologue is safe.
// testq/jz skips the check when the limit is NULL (main thread).
static const char kCheckAsm_x86_64[] =
    "0:\n\t"
    "movq test_stack_limit@gottpoff(%rip), %r11\n\t"
    "movq %fs:(%r11), %r11\n\t"
    "testq %r11, %r11\n\t"
    "jz 1f\n\t"
    "cmpq %r11, %rsp\n\t"
    "ja 1f\n\t"
    "callq __morestack\n\t"
    "jmp 0b\n\t"
    "1:";

namespace {

struct FiberStackCheckPass : public MachineFunctionPass {
    static char ID;
    FiberStackCheckPass() : MachineFunctionPass(ID) {}

    bool runOnMachineFunction(MachineFunction &MF) override {
        const Function &F = MF.getFunction();

        if (F.isDeclaration())
            return false;
        if (F.hasFnAttribute(Attribute::Naked))
            return false;

        StringRef Name = F.getName();
        if (Name == "__morestack" || Name == "__lessstack")
            return false;
        if (Name.starts_with("__fiber_") ||
            Name.starts_with("__mock_")  ||
            Name.starts_with("__zig_"))
            return false;

        Triple T(F.getParent()->getTargetTriple());
        if (T.getArch() != Triple::x86_64)
            return false;

        MachineBasicBlock &Entry = MF.front();
        const TargetInstrInfo *TII = MF.getSubtarget().getInstrInfo();

        // Insert at position 0 — BEFORE the prologue.
        MachineBasicBlock::iterator InsertPt = Entry.begin();
        DebugLoc DL;

        unsigned ExtraInfo =
            InlineAsm::Extra_HasSideEffects |
            InlineAsm::Extra_MayLoad        |
            InlineAsm::Extra_MayStore;

        BuildMI(Entry, InsertPt, DL,
                TII->get(TargetOpcode::INLINEASM))
            .addExternalSymbol(kCheckAsm_x86_64)
            .addImm(ExtraInfo);

        return true;
    }

    StringRef getPassName() const override {
        return "Fiber Stack Check (Machine Pass)";
    }
};

char FiberStackCheckPass::ID = 0;

} // anonymous namespace

static RegisterPass<FiberStackCheckPass> X(
    "fiber-stack-check",
    "Insert __morestack before prologue (machine pass)",
    false, false);
