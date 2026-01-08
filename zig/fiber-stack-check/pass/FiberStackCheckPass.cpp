#include "llvm/IR/PassManager.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/InlineAsm.h"
#include "llvm/Passes/PassPlugin.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/TargetParser/Triple.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/IR/DebugInfoMetadata.h"

using namespace llvm;

namespace {

struct FiberStackCheckPass : PassInfoMixin<FiberStackCheckPass> {
    PreservedAnalyses run(Function &F, FunctionAnalysisManager &) {
        // Skip declarations
        if (F.isDeclaration())
            return PreservedAnalyses::all();

        // Skip naked functions
        if (F.hasFnAttribute(Attribute::Naked))
            return PreservedAnalyses::all();

        // Skip the slow path itself
        if (F.getName() == "__morestack")
            return PreservedAnalyses::all();

        Module *M = F.getParent();
        LLVMContext &Ctx = M->getContext();

        // Determine target
        Triple T(M->getTargetTriple());
        bool IsX86 = T.getArch() == Triple::x86_64;
        bool IsARM = T.getArch() == Triple::aarch64;

        if (!IsX86 && !IsARM) {
            // Unsupported architecture
            return PreservedAnalyses::all();
        }

        // Types
        Type *VoidTy = Type::getVoidTy(Ctx);
        Type *Int8PtrTy = PointerType::getUnqual(Ctx);

        // Declare: extern threadlocal i8* __fiber_stack_limit
        GlobalVariable *LimitGV = M->getGlobalVariable("__fiber_stack_limit");
        if (!LimitGV) {
            LimitGV = new GlobalVariable(
                *M,
                Int8PtrTy,
                false,
                GlobalValue::ExternalLinkage,
                nullptr,
                "__fiber_stack_limit",
                nullptr,
                GlobalValue::LocalExecTLSModel,
                0,
                true // thread local
            );
        }
        else {
            // It exists (Zig defined it), but we MUST ensure the model is fast.
            // If it's "GeneralDynamic" (default), it might call __tls_get_addr and crash your stack.
            LimitGV->setThreadLocal(true);
            LimitGV->setThreadLocalMode(GlobalValue::LocalExecTLSModel);
        }

        // Declare: extern void __morestack() noreturn
        FunctionCallee SlowPath =
            M->getOrInsertFunction(
                "__morestack",
                FunctionType::get(VoidTy, {}, false));

        // Find insertion point at function entry
        BasicBlock &Entry = F.getEntryBlock();
        Instruction *InsertPt = &*Entry.getFirstInsertionPt();
        IRBuilder<> B(InsertPt);

        // If the function has debug info, our new instructions need it too.
        DebugLoc DL = InsertPt->getDebugLoc();
        // Fallback: If instruction has no debug info but function does, use Line 0
        if (!DL && F.getSubprogram()) {
             DL = DILocation::get(Ctx, 0, 0, F.getSubprogram());
        }
        if (DL) B.SetCurrentDebugLocation(DL);

        // Build inline asm to read SP
        FunctionType *AsmTy = FunctionType::get(Int8PtrTy, {}, false);
        InlineAsm *GetSP = nullptr;

        if (IsX86) {
            // x86_64: mov %rsp, $0
            GetSP = InlineAsm::get(AsmTy, "mov %rsp, $0", "=r", true);
        } else if (IsARM) {
            // AArch64: mov $0, sp
            GetSP = InlineAsm::get(AsmTy, "mov $0, sp", "=r", true);
        }

        Value *SP = B.CreateCall(GetSP);

        // Load stack limit
        Value *Limit = B.CreateLoad(Int8PtrTy, LimitGV);

        // Compare: if (sp < limit)
        Value *Cond = B.CreateICmpULT(SP, Limit);

        // Split block
        BasicBlock *SlowBB = BasicBlock::Create(Ctx, "stack_slow", &F);
        BasicBlock *ContBB = Entry.splitBasicBlock(InsertPt, "stack_ok");

        // Replace unconditional branch with conditional
        Entry.getTerminator()->eraseFromParent();
        B.SetInsertPoint(&Entry);
        B.CreateCondBr(Cond, SlowBB, ContBB);

        // Fill slow path
        IRBuilder<> SB(SlowBB);
        if (DL) SB.SetCurrentDebugLocation(DL);

        SB.CreateCall(SlowPath);
        SB.CreateUnreachable();

        return PreservedAnalyses::none();
    }
};

} // namespace

extern "C" LLVM_ATTRIBUTE_WEAK ::llvm::PassPluginLibraryInfo
llvmGetPassPluginInfo() {
    return {
        LLVM_PLUGIN_API_VERSION,
        "FiberStackCheck",
        "0.1",
        [](PassBuilder &PB) {
            // 1. Allow parsing it by name (optional, but good for debugging)
            PB.registerPipelineParsingCallback(
                [](StringRef Name, FunctionPassManager &FPM,
                   ArrayRef<PassBuilder::PipelineElement>) {
                    if (Name == "fiber-stack-check") {
                        FPM.addPass(FiberStackCheckPass());
                        return true;
                    }
                    return false;
                });

            // 2. Register for O0 (Debug) support
            // This runs at the start of the pipeline, ensuring it works in Debug builds.
            PB.registerPipelineStartEPCallback(
                [](ModulePassManager &MPM, OptimizationLevel Level) {
                    // We must wrap the FunctionPass in an adaptor for the ModuleManager
                    MPM.addPass(createModuleToFunctionPassAdaptor(FiberStackCheckPass()));
                });

            // 3. Keep this for release builds if needed,
            // though the PipelineStart callback usually covers both.
            PB.registerScalarOptimizerLateEPCallback(
                [](FunctionPassManager &FPM, OptimizationLevel Level) {
                    FPM.addPass(FiberStackCheckPass());
                });
        }
    };
}

