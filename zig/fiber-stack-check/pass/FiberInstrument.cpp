// FiberInstrument.cpp — Standalone codegen tool
//
// Reads LLVM bitcode, runs full x86-64 code generation with the
// FiberStackCheck machine pass injected AFTER PrologEpilogInserter,
// and writes an object file.  No MIR text round-tripping.
//
// Usage:
//   fiber-instrument input.bc -o output.o

#include "llvm/CodeGen/CommandFlags.h"
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/CodeGen/MachineBasicBlock.h"
#include "llvm/CodeGen/MachineFunction.h"
#include "llvm/CodeGen/MachineInstrBuilder.h"
#include "llvm/CodeGen/Passes.h"            // PrologEpilogCodeInserterID
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
// Delegates everything to the real TM but overrides createPassConfig
// to inject FiberStackCheckPass after PrologEpilogCodeInserter.
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
        // Share the MC objects from the real target machine.
        // We do NOT call initAsmInfo() — the inner TM already owns these.
        AsmInfo.reset(const_cast<MCAsmInfo *>(TM->getMCAsmInfo()));
        MRI.reset(const_cast<MCRegisterInfo *>(TM->getMCRegisterInfo()));
        MII.reset(const_cast<MCInstrInfo *>(TM->getMCInstrInfo()));
        STI.reset(const_cast<MCSubtargetInfo *>(TM->getMCSubtargetInfo()));
    }

    ~FiberTargetMachine() override {
        // Release without deleting — Inner still owns these.
        (void)AsmInfo.release();
        (void)MRI.release();
        (void)MII.release();
        (void)STI.release();
    }

    const TargetSubtargetInfo *
    getSubtargetImpl(const Function &F) const override {
        return Inner->getSubtargetImpl(F);
    }

    TargetPassConfig *createPassConfig(PassManagerBase &PM) override {
        // Let the real target build its pass config.
        TargetPassConfig *Config = Inner->createPassConfig(PM);
        // Inject our pass right after prologue/epilogue insertion.
        Config->insertPass(&PrologEpilogCodeInserterID,
                           &FiberStackCheckPass::ID);
        return Config;
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
        "  function prologue, writes an object file.\n");

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

    // 3. Create the real target machine
    CodeGenOptLevel OLvl = CodeGenOptLevel::None;
    switch (OptLevel) {
    case '1': OLvl = CodeGenOptLevel::Less;       break;
    case '2': OLvl = CodeGenOptLevel::Default;    break;
    case '3': OLvl = CodeGenOptLevel::Aggressive; break;
    default:  OLvl = CodeGenOptLevel::None;       break;
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

    // 4. Wrap it to inject our machine pass
    FiberTargetMachine FTM(
        static_cast<LLVMTargetMachine *>(RealTM.get()));

    // 5. Build codegen pipeline and emit
    legacy::PassManager PM;

    std::error_code EC;
    raw_fd_ostream Out(OutputFilename, EC, sys::fs::OF_None);
    if (EC) {
        errs() << argv[0] << ": " << EC.message() << "\n";
        return 1;
    }

    if (FTM.addPassesToEmitFile(PM, Out, nullptr,
                                CodeGenFileType::ObjectFile)) {
        errs() << argv[0]
               << ": target does not support object emission\n";
        return 1;
    }

    PM.run(*M);
    Out.flush();

    outs() << "fiber-instrument: wrote " << OutputFilename << "\n";
    return 0;
}
