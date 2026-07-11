require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe "fallible pipeline CATCH snapshots" do
  it "captures the pipeline input before invoking a fallible function" do
    source = <<~CLEAR
      STRUCT User { name: String, age: Int64 }
      FN validate(user: User) RETURNS !User ->
        IF user.age < 0_i64 THEN RAISE Input; END
        RETURN user;
      END
      FN process(user: User) RETURNS !String ->
        valid = user |> validate;
        RETURN valid.name;
      CATCH Input
        RETURN snapshot.name;
      END
    CLEAR

    zig = ZigTranspiler.new(source_dir: Dir.pwd).transpile(source, source_dir: Dir.pwd)

    expect(zig).to include("captureSnapshot")
    expect(zig).to match(/captureSnapshot\([^\n]*User/)
  end
end
