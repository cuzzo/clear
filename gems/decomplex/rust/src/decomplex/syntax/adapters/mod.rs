pub(crate) mod base;
mod c;
mod cpp;
mod csharp;
pub(crate) mod false_simplicity_lexicon;
mod go;
mod java;
mod javascript;
mod kotlin;
mod lua;
mod php;
mod python;
mod ruby;
mod ruby_data;
mod rust;
mod swift;
mod typescript;
mod zig;

pub(crate) use base::LanguageProfile;

use super::Language;
use c::CProfile;
use cpp::CppProfile;
use csharp::CSharpProfile;
use go::GoProfile;
use java::JavaProfile;
use javascript::JavaScriptProfile;
use kotlin::KotlinProfile;
use lua::LuaProfile;
use php::PhpProfile;
use python::PythonProfile;
use ruby::RubyProfile;
use rust::RustProfile;
use swift::SwiftProfile;
use typescript::TypeScriptProfile;
use zig::ZigProfile;

static RUBY_PROFILE: RubyProfile = RubyProfile;
static PYTHON_PROFILE: PythonProfile = PythonProfile;
static JAVASCRIPT_PROFILE: JavaScriptProfile = JavaScriptProfile;
static JAVA_PROFILE: JavaProfile = JavaProfile;
static TYPESCRIPT_PROFILE: TypeScriptProfile = TypeScriptProfile;
static SWIFT_PROFILE: SwiftProfile = SwiftProfile;
static KOTLIN_PROFILE: KotlinProfile = KotlinProfile;
static GO_PROFILE: GoProfile = GoProfile;
static RUST_PROFILE: RustProfile = RustProfile;
static ZIG_PROFILE: ZigProfile = ZigProfile;
static LUA_PROFILE: LuaProfile = LuaProfile;
static C_PROFILE: CProfile = CProfile;
static CPP_PROFILE: CppProfile = CppProfile;
static CSHARP_PROFILE: CSharpProfile = CSharpProfile;
static PHP_PROFILE: PhpProfile = PhpProfile;

pub(crate) fn language_profile(language: Language) -> &'static dyn LanguageProfile {
    match language {
        Language::Ruby => &RUBY_PROFILE,
        Language::Python => &PYTHON_PROFILE,
        Language::JavaScript => &JAVASCRIPT_PROFILE,
        Language::Java => &JAVA_PROFILE,
        Language::TypeScript => &TYPESCRIPT_PROFILE,
        Language::Swift => &SWIFT_PROFILE,
        Language::Kotlin => &KOTLIN_PROFILE,
        Language::Go => &GO_PROFILE,
        Language::Rust => &RUST_PROFILE,
        Language::Zig => &ZIG_PROFILE,
        Language::Lua => &LUA_PROFILE,
        Language::C => &C_PROFILE,
        Language::Cpp => &CPP_PROFILE,
        Language::CSharp => &CSHARP_PROFILE,
        Language::Php => &PHP_PROFILE,
    }
}
