// FiberInstrument.cpp — Standalone codegen tool
//
// Reads LLVM bitcode, runs full x86-64 code generation with the
// FiberStackCheck machine pass injected AFTER PrologEpilogInserter,
// and writes an object file.  No MIR text round-tripping.
//
// Usage:
//   fiber-instrument input.bc -o output.o
//   fiber-instrument input.bc -S -o output.s   # emit assembly
//
// How it works:
//   A thin wrapper around the real TargetMachine overrides only
//   createPassConfig() to call insertPass().  Every other virtual
//   method delegates to the real TM, so AsmPrinter, ISel, and
//   register allocation all see the real target state.

#include "llvm/CodeGen/CommandFlags.h"
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/CodeGen/MachineBasicBlock.h"
#include "llvm/CodeGen/MachineFunction.h"
#include "llvm/CodeGen/MachineInstrBuilder.h"
#include "llvm/CodeGen/Passes.h"
#include "llvm/CodeGen/TargetInstrInfo.h"
#include "llvm/CodeGen/TargetPassConfig.h"
#include "llvm/CodeGen/TargetSubtargetInfo.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/InlineAsm.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/LegacyPassManager.h"
#include "llvm/IR/Module.h"
#include "llvm/IRReader/IRReader.h"
#include "llvm/MC/MCAsmInfo.h"
#include "llvm/MC/MCInstrInfo.h"
#include "llvm/MC/MCRegisterInfo.h"
#include "llvm/MC/MCSubtargetInfo.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Analysis/TargetTransformInfo.h"
#include "llvm/Pass.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/InitLLVM.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/Target/TargetLoweringObjectFile.h"
#include "llvm/TargetParser/Triple.h"

using namespace llvm;

// ── CLI ──────────────────────────────────────────────────────────
static cl::opt<std::string> InputFilename(cl::Positional,
    cl::desc("<input bitcode>"), cl::Required);
static cl::opt<std::string> OutputFilename("o",
    cl::desc("Output filename"), cl::value_desc("filename"),
    cl::init("a.o"));
static cl::opt<char> OptLevel("O",
    cl::desc("Optimization level (0-3)"), cl::init('0'));
static cl::opt<bool> EmitAsm("S",
    cl::desc("Emit assembly instead of object"), cl::init(false));

static codegen::RegisterCodeGenFlags CGF;

// ── The Machine Pass ─────────────────────────────────────────────
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

        if (F.isDeclaration()) return false;
        if (F.hasFnAttribute(Attribute::Naked)) return false;

        StringRef Name = F.getName();
        if (Name == "__morestack" || Name == "__lessstack") return false;
        if (Name.starts_with("__fiber_") ||
            Name.starts_with("__mock_")  ||
            Name.starts_with("__zig_"))
            return false;

        Triple T(F.getParent()->getTargetTriple());
        if (T.getArch() != Triple::x86_64) return false;

        MachineBasicBlock &Entry = MF.front();
        const TargetInstrInfo *TII = MF.getSubtarget().getInstrInfo();
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

static RegisterPass<FiberStackCheckPass> Reg(
    "fiber-stack-check",
    "Insert __morestack before prologue (machine pass)",
    false, false);

// ── Wrapper TargetMachine ────────────────────────────────────────
// Thin wrapper that delegates EVERYTHING to the real TM except
// createPassConfig(), where we call insertPass() to inject our
// machine pass after PrologEpilogCodeInserter.
//
// The MC objects (AsmInfo, MRI, MII, STI) are borrowed from Inner
// and released (not deleted) in the destructor.
namespace {

class FiberTargetMachine : public LLVMTargetMachine {
    LLVMTargetMachine *Inner;

public:
    FiberTargetMachine(LLVMTargetMachine *TM)
        : LLVMTargetMachine(
              TM->getTarget(),
              TM->createDataLayout().getStringRepresentation(),
              TM->getTargetTriple(),
              TM->getTargetCPU(),
              TM->getTargetFeatureString(),
              TM->Options,
              TM->getRelocationModel(),
              TM->getCodeModel(),
              TM->getOptLevel()),
          Inner(TM) {
        // Borrow MC objects from the real TM (don't call initAsmInfo).
        AsmInfo.reset(const_cast<MCAsmInfo *>(TM->getMCAsmInfo()));
        MRI.reset(const_cast<MCRegisterInfo *>(TM->getMCRegisterInfo()));
        MII.reset(const_cast<MCInstrInfo *>(TM->getMCInstrInfo()));
        STI.reset(const_cast<MCSubtargetInfo *>(TM->getMCSubtargetInfo()));
    }

    ~FiberTargetMachine() override {
        // Release without deleting — Inner owns these.
        (void)AsmInfo.release();
        (void)MRI.release();
        (void)MII.release();
        (void)STI.release();
    }

    // ── The one method we actually change ────────────────────────
    TargetPassConfig *createPassConfig(PassManagerBase &PM) override {
        TargetPassConfig *Config = Inner->createPassConfig(PM);
        // Uncomment to inject our pass:
        Config->insertPass(&PrologEpilogCodeInserterID,
                           &FiberStackCheckPass::ID);
        return Config;
    }

    // Ensure callers see Inner's subtarget, not a stale one from
    // our wrapper's base class.
    bool isNoopAddrSpaceCast(unsigned SrcAS, unsigned DstAS) const override {
        return Inner->isNoopAddrSpaceCast(SrcAS, DstAS);
    }

    // ── Delegate everything else to Inner ────────────────────────
    const TargetSubtargetInfo *
    getSubtargetImpl(const Function &F) const override {
        auto *STI = Inner->getSubtargetImpl(F);
        if (!STI)
            errs() << "WARNING: getSubtargetImpl returned null for "
                   << F.getName() << "\n";
        return STI;
    }

    TargetLoweringObjectFile *getObjFileLowering() const override {
        return Inner->getObjFileLowering();
    }

    TargetTransformInfo
    getTargetTransformInfo(const Function &F) const override {
        return Inner->getTargetTransformInfo(F);
    }
};

} // anonymous namespace

// ── main ─────────────────────────────────────────────────────────
int main(int argc, char **argv) {
    InitLLVM Init(argc, argv);

    InitializeAllTargets();
    InitializeAllTargetMCs();
    InitializeAllAsmPrinters();
    InitializeAllAsmParsers();

    cl::ParseCommandLineOptions(argc, argv,
        "Fiber stack-check instrumenting compiler\n"
        "  Reads LLVM bitcode, inserts __morestack before every\n"
        "  function prologue, writes object file or assembly.\n");

    // 1. Read input
    LLVMContext Ctx;
    SMDiagnostic Err;
    std::unique_ptr<Module> M = parseIRFile(InputFilename, Err, Ctx);
    if (!M) {
        Err.print(argv[0], errs());
        return 1;
    }

    // 2. Look up target
    Triple TheTriple(M->getTargetTriple());
    std::string LookupError;
    const Target *TheTarget =
        TargetRegistry::lookupTarget(TheTriple.str(), LookupError);
    if (!TheTarget) {
        errs() << argv[0] << ": " << LookupError << "\n";
        return 1;
    }

    // 3. Create real target machine
    CodeGenOptLevel OLvl = CodeGenOptLevel::None;
    switch (OptLevel) {
    case '1': OLvl = CodeGenOptLevel::Less;       break;
    case '2': OLvl = CodeGenOptLevel::Default;    break;
    case '3': OLvl = CodeGenOptLevel::Aggressive; break;
    }

    TargetOptions Options;
    std::unique_ptr<TargetMachine> RealTM(TheTarget->createTargetMachine(
        TheTriple.str(),
        codegen::getCPUStr(),
        codegen::getFeaturesStr(),
        Options,
        codegen::getExplicitRelocModel(),
        codegen::getExplicitCodeModel(),
        OLvl));

    if (!RealTM) {
        errs() << argv[0] << ": could not create target machine\n";
        return 1;
    }

    M->setDataLayout(RealTM->createDataLayout());

    // 4. Wrap the TM to inject our pass
    FiberTargetMachine FTM(
        static_cast<LLVMTargetMachine *>(RealTM.get()));

    // 5. Build codegen pipeline and emit.
    //    PM and Out must be destroyed BEFORE FTM/RealTM (the
    //    AsmPrinter holds a reference to the TM, and the MC
    //    streamer references the output stream).
    {
        legacy::PassManager PM;

        std::error_code EC;
        raw_fd_ostream Out(OutputFilename, EC, sys::fs::OF_None);
        if (EC) {
            errs() << argv[0] << ": " << EC.message() << "\n";
            return 1;
        }

        CodeGenFileType FT = EmitAsm ? CodeGenFileType::AssemblyFile
                                     : CodeGenFileType::ObjectFile;

        if (FTM.addPassesToEmitFile(PM, Out, nullptr, FT)) {
            errs() << argv[0]
                   << ": target does not support code generation\n";
            return 1;
        }

        PM.run(*M);
        Out.flush();
    }

    return 0;
}
