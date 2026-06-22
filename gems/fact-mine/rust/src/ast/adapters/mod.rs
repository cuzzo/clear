pub(crate) mod base;
mod c;
mod cpp;
mod csharp;
mod go;
mod java;
mod javascript;
mod kotlin;
mod lua;
mod php;
mod python;
mod ruby;
mod rust;
mod swift;
mod typescript;
mod zig;

pub(crate) use base::{AstNormalizationAdapter, NamedChildrenAction};

use crate::syntax::Language;
use c::CAstAdapter;
use cpp::CppAstAdapter;
use csharp::CSharpAstAdapter;
use go::GoAstAdapter;
use java::JavaAstAdapter;
use javascript::JavaScriptAstAdapter;
use kotlin::KotlinAstAdapter;
use lua::LuaAstAdapter;
use php::PhpAstAdapter;
use python::PythonAstAdapter;
use ruby::RubyAstAdapter;
use rust::RustAstAdapter;
use swift::SwiftAstAdapter;
use typescript::TypeScriptAstAdapter;
use zig::ZigAstAdapter;

pub(in crate::ast) use ruby::{
    dynamic_constant_pattern_text, dynamic_exception_constant_text, dynamic_instance_variable_text,
};

static RUBY: RubyAstAdapter = RubyAstAdapter;
static PYTHON: PythonAstAdapter = PythonAstAdapter;
static JAVASCRIPT: JavaScriptAstAdapter = JavaScriptAstAdapter;
static TYPESCRIPT: TypeScriptAstAdapter = TypeScriptAstAdapter;
static LUA: LuaAstAdapter = LuaAstAdapter;
static C: CAstAdapter = CAstAdapter;
static CPP: CppAstAdapter = CppAstAdapter;
static CSHARP: CSharpAstAdapter = CSharpAstAdapter;
static GO: GoAstAdapter = GoAstAdapter;
static JAVA: JavaAstAdapter = JavaAstAdapter;
static KOTLIN: KotlinAstAdapter = KotlinAstAdapter;
static RUST: RustAstAdapter = RustAstAdapter;
static SWIFT: SwiftAstAdapter = SwiftAstAdapter;
static ZIG: ZigAstAdapter = ZigAstAdapter;
static PHP: PhpAstAdapter = PhpAstAdapter;

pub(crate) fn normalization_adapter(language: Language) -> &'static dyn AstNormalizationAdapter {
    match language {
        Language::Ruby => &RUBY,
        Language::Python => &PYTHON,
        Language::JavaScript => &JAVASCRIPT,
        Language::TypeScript => &TYPESCRIPT,
        Language::Lua => &LUA,
        Language::C => &C,
        Language::Cpp => &CPP,
        Language::CSharp => &CSHARP,
        Language::Go => &GO,
        Language::Java => &JAVA,
        Language::Kotlin => &KOTLIN,
        Language::Rust => &RUST,
        Language::Swift => &SWIFT,
        Language::Zig => &ZIG,
        Language::Php => &PHP,
    }
}
