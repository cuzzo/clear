# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../ruby/ast/parser"
require_relative "../ruby/annotator"
require_relative "../ruby/semantic/tense_operation_plan"
require_relative "../../tools/fuzz/select_tense_semantics"

RSpec.describe TenseOperationPlanner do
  def annotated_function(source, name)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    SemanticAnnotator.new(source_code: source).annotate!(ast)
    T.cast(ast.statements.find { |statement| statement.is_a?(AST::FunctionDef) && statement.name == name }, AST::FunctionDef)
  end

  def expression_for(order, payload = NamedTypeExpression.new(name: :Int64))
    order.reverse.each_char.reduce(payload) do |inner, marker|
      case marker
      when "!" then FallibleTypeExpression.new(inner: inner)
      when "~" then FutureTypeExpression.new(inner: inner)
      when "?" then OptionalTypeExpression.new(inner: inner)
      else raise "unknown test marker #{marker}"
      end
    end
  end

  it "extracts and reconstructs every independently specified SELECT order" do
    SelectTenseSemantics::VALID_ORDERS.each do |order|
      expression = expression_for(order)
      envelope = TenseEnvelope.from_expression(expression)

      expect(envelope.order).to eq(order)
      expect(envelope.valid?).to be(true)
      expect(TypeExpressionPrinter.semantic(envelope.wrap(envelope.payload_expression))).to(
        eq(TypeExpressionPrinter.semantic(expression)),
      )
      expect(envelope.payload_type.resolved).to eq(:Int64)
    end
  end

  it "rejects every independently specified invalid order" do
    SelectTenseSemantics::INVALID_ORDERS.each do |order|
      expect { TenseEnvelope.from_expression(expression_for(order)) }.to(
        raise_error(ArgumentError, /unsupported tense order/),
      )
    end
    expect { TenseEnvelope.from_expression(expression_for("!!")) }.to(
      raise_error(ArgumentError, /unsupported tense order/),
    )
  end

  it "classifies selector effects without flattening temporal order" do
    {
      "" => [nil, false, false],
      "?" => [:optional, false, false],
      "!" => [:fallible, false, true],
      "!?" => [:fallible_optional, false, true],
      "~" => [nil, true, false],
      "~!?" => [:fallible_optional, true, true],
      "!~" => [:fallible, true, true],
      "!~!?" => [:fallible_optional, true, true],
    }.each do |order, (mode, asynchronous, fallible)|
      plan = described_class.selector(Type.new(expression_for(order)))
      expect(plan.required_order).to eq(order)
      expect(plan.required_mode).to eq(mode)
      expect(plan.asynchronous?).to be(asynchronous)
      expect(plan.fallible?).to be(fallible)
      expect(plan.leaf_type.resolved).to eq(:Int64)
      expect(plan.value_type.semantic_type_key).to eq(Type.new(expression_for(order)).semantic_type_key)
    end
  end

  it "turns the future boundary into a stream while retaining layers on both sides" do
    {
      "" => "[~]Int64",
      "!?" => "[~]!?Int64",
      "~!?" => "[~]!?Int64",
      "!~" => "![~]Int64",
      "!~!?" => "![~]!?Int64",
    }.each do |order, expected|
      plan = described_class.selector(Type.new(expression_for(order)))
      actual = TypeExpressionPrinter.inline(plan.stream_result_type(:FINITE).shape.expression)
      expect(actual).to eq(expected)
    end
  end

  it "preserves capabilities and fallible error sets while rebuilding layers" do
    future_capabilities = TypeCapabilities.new(ownership: :shared, ownership_set: true)
    optional_capabilities = TypeCapabilities.new(sync: :locked)
    error_set = NamedTypeExpression.new(name: :Failure)
    expression = FutureTypeExpression.new(
      capabilities: future_capabilities,
      inner: FallibleTypeExpression.new(
        error_set: error_set,
        inner: OptionalTypeExpression.new(
          capabilities: optional_capabilities,
          inner: NamedTypeExpression.new(name: :Value),
        ),
      ),
    )

    rebuilt = TenseEnvelope.from_type(Type.new(expression)).wrap(NamedTypeExpression.new(name: :Other))
    expect(rebuilt).to be_a(FutureTypeExpression)
    future = rebuilt
    expect(future.capabilities).to equal(future_capabilities)
    expect(future.inner).to be_a(FallibleTypeExpression)
    fallible = future.inner
    expect(fallible.error_set).to equal(error_set)
    expect(fallible.inner).to be_a(OptionalTypeExpression)
    expect(fallible.inner.capabilities).to equal(optional_capabilities)
  end

  it "plans TRY without losing the untouched ordered layers" do
    {
      "!" => ["", TenseBackendForm::ZigTry, TensePropagation::Failure],
      "!?" => ["?", TenseBackendForm::ZigTry, TensePropagation::Failure],
      "!~!?" => ["~!?", TenseBackendForm::ZigTry, TensePropagation::Failure],
      "?" => ["", TenseBackendForm::OptionalTry, TensePropagation::AbsenceAsFailure],
    }.each do |order, (result_order, backend, propagation)|
      plan = described_class.try_value(Type.new(expression_for(order)))
      expect(plan.operation).to eq(TenseOperationKind::Try)
      expect(plan.backend_form).to eq(backend)
      expect(plan.propagation).to eq(propagation)
      expect(plan.may_terminate_current_flow).to be(true)
      expect(plan.consumed_layers.map(&:marker).join).to eq(order[0])
      expect(TenseEnvelope.from_type(plan.result_type).order).to eq(result_order)
    end
    expect { described_class.try_value(Type.new(:Int64)) }.to raise_error(ArgumentError, /TRY requires/)
  end

  it "plans UNWRAP through an available error layer but never through a future" do
    optional = described_class.unwrap(Type.new("?Int64"))
    fallible_optional = described_class.unwrap(Type.new("!?Int64"))

    expect(Type.surface_name(optional.result_type)).to eq("Int64")
    expect(Type.surface_name(fallible_optional.result_type)).to eq("!Int64")
    expect(fallible_optional.consumed_layers.map(&:kind)).to eq([TenseLayerKind::Optional])
    expect(fallible_optional.preserved_layers.map(&:kind)).to eq([TenseLayerKind::Fallible])
    expect { described_class.unwrap(Type.new("~?Int64")) }.to raise_error(ArgumentError, /immediately available/)
    expect { described_class.unwrap(Type.new(:Int64)) }.to raise_error(ArgumentError, /UNWRAP requires/)
  end

  it "preserves value capabilities and placement when consuming a layer" do
    source = Type.new("!?String", ownership: :shared, sync: :locked, location: :heap)
    unwrapped = described_class.unwrap(source).result_type
    tried = described_class.try_value(source).result_type

    [unwrapped, tried].each do |result|
      expect(result.ownership).to eq(:shared)
      expect(result.sync).to eq(:locked)
      expect(result.location).to eq(:heap)
    end
  end

  it "plans affine and shared scalar NEXT with explicit handle behavior" do
    affine = described_class.next_value(Type.new("~!Int64"))
    shared = described_class.next_value(Type.new("~?Int64", ownership: :shared), shared: true)
    observable = described_class.next_value(Type.new("~String", observable: true))

    expect(Type.surface_name(affine.result_type)).to eq("!Int64")
    expect(affine.backend_form).to eq(TenseBackendForm::PromiseNext)
    expect(affine.consumes_handle?).to be(true)
    expect(affine.suspends).to be(true)
    expect(Type.surface_name(shared.result_type)).to eq("?Int64")
    expect(shared.backend_form).to eq(TenseBackendForm::SharedPromiseNext)
    expect(shared.handle_use).to eq(TenseHandleUse::SharedRead)
    expect(observable.backend_form).to eq(TenseBackendForm::ObservableStringNext)
    expect(shared.consumes_handle?).to be(false)
    expect { described_class.next_value(Type.new("!~Int64")) }.to raise_error(ArgumentError, /outer future/)
  end

  it "plans fallible and optional predicates with refinement types" do
    ok = described_class.is_ok(Type.new("!?Int64"))
    exists = described_class.exists(Type.new("!?Int64"))

    expect(ok.backend_form).to eq(TenseBackendForm::FallibleTest)
    expect(Type.surface_name(T.must(ok.refinement_type))).to eq("?Int64")
    expect(exists.backend_form).to eq(TenseBackendForm::OptionalTest)
    expect(Type.surface_name(T.must(exists.refinement_type))).to eq("!Int64")
    expect { described_class.is_ok(Type.new("?Int64")) }.to raise_error(ArgumentError, /IS_OK requires/)
    expect { described_class.exists(Type.new("~?Int64")) }.to raise_error(ArgumentError, /immediately available/)
  end

  it "maps every valid ordered receiver envelope without flattening it" do
    TenseOperationPlanner::NAVIGATION_MARKERS.each do |order|
      source = Type.new(expression_for(order))
      plan = described_class.navigate(source, Type.new(:String), markers: order)

      expect(plan.operation).to eq(TenseOperationKind::Navigate)
      expect(TenseEnvelope.from_type(plan.result_type).order).to eq(order)
      expect(TenseEnvelope.from_type(plan.result_type).payload_type.resolved).to eq(:String)
      expect(plan.navigation_layers.map(&:marker).join).to eq(order)
      expect(plan.backend_form).to eq(order.include?("~") ? TenseBackendForm::FutureMap : TenseBackendForm::DirectMap)
      expect(plan.suspends).to be(false)
    end
  end

  it "normalizes immediate mapped effects while preserving the future boundary" do
    {
      ["?", "!"] => "!?",
      ["!", "?"] => "!?",
      ["!?", "!?"] => "!?",
      ["~?", "!"] => "~!?",
      ["!~?", "!?"] => "!~!?",
      ["!", "~"] => "!~",
    }.each do |(receiver_order, member_order), expected|
      plan = described_class.navigate(
        Type.new(expression_for(receiver_order)),
        Type.new(expression_for(member_order, NamedTypeExpression.new(name: :String))),
        markers: receiver_order,
      )
      expect(TenseEnvelope.from_type(plan.result_type).order).to eq(expected)
    end
  end

  it "makes future handle ownership explicit and rejects ambiguous navigation" do
    affine = described_class.navigate(Type.new("~Int64"), Type.new(:String), markers: "~")
    shared = described_class.navigate(
      Type.new("~Int64", ownership: :shared), Type.new(:String), markers: "~", shared: true,
    )

    expect(affine.handle_use).to eq(TenseHandleUse::Consume)
    expect(shared.handle_use).to eq(TenseHandleUse::SharedRead)
    expect { described_class.navigate(Type.new("!?Int64"), Type.new(:String), markers: "?!") }.to(
      raise_error(ArgumentError, /must match receiver tense order/),
    )
    expect { described_class.navigate(Type.new("~Int64"), Type.new("~String"), markers: "~") }.to(
      raise_error(ArgumentError, /nested future/),
    )
    expect { described_class.navigate(Type.new("~Int64[]"), Type.new(:String), markers: "~") }.to(
      raise_error(ArgumentError, /streams require SELECT/),
    )
  end


  it "keeps navigation node names and direct borrowed payloads structural" do
    token = Lexer::Token.new(:VAR_ID, "value", 1, 1)
    unnamed = AST::TenseNavigation.new(token, AST::Literal.new(token, :INT64, 1, nil), "!")
    expect(unnamed.name).to be_nil

    target = AST::Identifier.new(token, "foreign")
    target.full_type = Type.new("!?[]@c Int64")
    target.container_borrow = true
    navigation = AST::TenseNavigation.new(token, target, "!?")
    member = AST::Identifier.new(token, "mapped")
    annotator = Annotator::Phases::TypeAnalysisSession.new(source_code: "")

    result = annotator.send(:publish_tense_navigation_plan!, member, navigation, Type.new(:Int64))
    expect(Type.surface_name(result)).to eq("!?Int64")
    expect(member.container_borrow).to be(true)
  end

  it "preserves unexpected planner failures at the annotation handoff" do
    token = Lexer::Token.new(:VAR_ID, "stream", 1, 1)
    target = AST::Identifier.new(token, "stream")
    target.full_type = Type.new("~Int64[]")
    navigation = AST::TenseNavigation.new(token, target, "~")
    member = AST::Identifier.new(token, "mapped")

    expect {
      Annotator::Phases::TypeAnalysisSession.new(source_code: "").send(
        :publish_tense_navigation_plan!, member, navigation, Type.new(:Int64),
      )
    }.to raise_error(ArgumentError, /streams require SELECT/)
  end

  it "parses ordered navigation as one transparent receiver boundary" do
    source = <<~CLEAR
      STRUCT User { name: String }
      FN main(value: !~?User) ->
        name: !~?String = value!~?.name;
      END
    CLEAR
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    main = T.cast(ast.statements.last, AST::FunctionDef)
    field = T.cast(T.cast(main.body.first, AST::BindExpr).value, AST::GetField)
    navigation = T.cast(field.target, AST::TenseNavigation)

    expect(navigation.markers).to eq("!~?")
    expect(navigation.target).to be_a(AST::Identifier)
    expect(field.field).to eq("name")
  end

  it "parses every valid navigation marker in the independently specified order table" do
    markers = SelectTenseSemantics::VALID_ORDERS.reject { |order| order.empty? || order == "?" }
    params = markers.each_with_index.map { |order, index| "v#{index}: #{order}User" }.join(", ")
    body = markers.each_with_index.map do |order, index|
      "mapped#{index}: #{order}String = v#{index}#{order}.name;"
    end.join("\n")
    source = <<~CLEAR
      STRUCT User { name: String }
      FN main(#{params}) ->
        #{body}
      END
    CLEAR

    main = T.cast(ClearParser.new(Lexer.new(source).tokenize, source).parse.statements.last, AST::FunctionDef)
    parsed = main.body.map do |statement|
      field = T.cast(T.cast(statement, AST::BindExpr).value, AST::GetField)
      T.cast(field.target, AST::TenseNavigation).markers
    end
    expect(parsed).to eq(markers)
  end

  it "retains the established optional safe-navigation node for mutable access paths" do
    source = "STRUCT User { name: String } FN main(v: ?User) -> x = v?.name; END"
    main = T.cast(ClearParser.new(Lexer.new(source).tokenize, source).parse.statements.last, AST::FunctionDef)
    field = T.cast(T.cast(main.body.first, AST::BindExpr).value, AST::GetField)

    expect(field.target).to be_a(AST::OptionalUnwrap)
    expect(T.cast(field.target, AST::OptionalUnwrap).safe_navigation?).to be(true)
  end

  it "preserves immediate payload capabilities without leaking future-handle capabilities" do
    immediate = described_class.navigation_payload(Type.new("?User", ownership: :multiowned))
    future = described_class.navigation_payload(Type.new("~User", ownership: :shared))

    expect(immediate.ownership).to eq(:multiowned)
    expect(future.ownership).to eq(:affine)
    expect(future.resolved).to eq(:User)
  end

  it "emits stable diagnostics for invalid, skipped, stream, and nested-future navigation" do
    malformed = "STRUCT User { name: String } FN main(v: !?User) -> x = v?!.name; END"
    expect do
      ClearParser.new(Lexer.new(malformed).tokenize, malformed).parse
    end.to raise_error(ParserError) { |error| expect(error.code).to eq(:TENSE_NAVIGATION_ORDER) }

    skipped = "STRUCT User { name: String } FN main(v: !?User) -> x:!?String = v!.name; END"
    expect do
      annotated_function(skipped, "main")
    end.to raise_error(CompilerError) do |error|
      expect(error.code).to eq(:TENSE_NAVIGATION_MISMATCH)
      expect(error.original_message).to include("use `!?.`")
    end

    stream = <<~CLEAR
      STRUCT User { name: String }
      FN main(v: [~]User) -> x = v~.name; END
    CLEAR
    expect { annotated_function(stream, "main") }.to raise_error(CompilerError) do |error|
      expect(error.code).to eq(:TENSE_NAVIGATION_STREAM)
    end

    nested = <<~CLEAR
      STRUCT User { id: Int64 }
      IMPLEMENTATION User {
        METHOD later(self) RETURNS ~Int64 -> RETURN BG { self.id; }; END
      }
      FN main(v: ~User) -> x: ~Int64 = v~.later(); END
    CLEAR
    expect { annotated_function(nested, "main") }.to raise_error(CompilerError) do |error|
      expect(error.code).to eq(:TENSE_NAVIGATION_NESTED_FUTURE)
    end

    mutation = <<~CLEAR
      STRUCT Counter { value: Int64 }
      FN main(v: ~Counter) -> v~.value = 2; END
    CLEAR
    expect { annotated_function(mutation, "main") }.to raise_error(CompilerError) do |error|
      expect(error.code).to eq(:TENSE_NAVIGATION_MUTATION)
      expect(error.original_message).to include("cannot mutate an unresolved future payload")
    end

    token = Lexer::Token.new(:VAR_ID, "future", 1, 1)
    target = AST::Identifier.new(token, "future")
    target.full_type = Type.new("~Counter")
    navigation = AST::TenseNavigation.new(token, target, "~")
    method = AST::MethodCall.new(token, navigation, "update", [])
    method.full_type = Type.new(:Void)
    method.mutates_receiver = true
    expect {
      Annotator::Phases::TypeAnalysisSession.new(source_code: "").send(
        :finalize_tense_navigation_method!, method,
      )
    }.to raise_error(CompilerError) do |error|
      expect(error.code).to eq(:TENSE_NAVIGATION_MUTATION)
    end
  end

  it "keeps postfix optional unwrap distinct from future tense navigation" do
    source = <<~CLEAR
      STRUCT User { name: String }
      FN main(user: ?User) ->
        definite = user?;
        maybeName = user?.name;
      END
    CLEAR
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    main = T.cast(ast.statements.last, AST::FunctionDef)
    definite = T.cast(main.body[0], AST::BindExpr).value
    maybe_field = T.cast(T.cast(main.body[1], AST::BindExpr).value, AST::GetField)

    expect(definite).to be_a(AST::OptionalUnwrap)
    expect(maybe_field.target).to be_a(AST::OptionalUnwrap)
    expect(T.cast(maybe_field.target, AST::OptionalUnwrap).safe_navigation?).to be(true)
  end

  it "annotates field navigation through ordered layers with one immutable plan" do
    source = <<~CLEAR
      STRUCT User { name: String }
      FN main(value: ~?User) RETURNS ~?String ->
        RETURN value~?.name;
      END
    CLEAR
    main = annotated_function(source, "main")
    field = T.cast(T.cast(main.body.first, AST::ReturnNode).value, AST::GetField)
    plan = T.cast(field.tense_plan, TenseOperationPlan)

    expect(Type.surface_name(field.full_type!(context: "test field"))).to eq("~?String")
    expect(plan.backend_form).to eq(TenseBackendForm::FutureMap)
    expect(plan.handle_use).to eq(TenseHandleUse::Consume)
  end

  it "applies the same navigation plan to extern methods" do
    source = <<~CLEAR
      EXTERN STRUCT Handle {} FROM "native";
      EXTERN FN Handle.id(self: Handle) RETURNS Int64 FROM "native";
      FN main(value: ~Handle) RETURNS ~Int64 ->
        RETURN value~.id();
      END
    CLEAR
    main = annotated_function(source, "main")
    method = T.cast(T.cast(main.body.first, AST::ReturnNode).value, AST::MethodCall)
    plan = T.cast(method.tense_plan, TenseOperationPlan)

    expect(plan.backend_form).to eq(TenseBackendForm::FutureMap)
    expect(Type.surface_name(method.full_type!(context: "test extern method"))).to eq("~Int64")
  end

  it "plans value and control-flow recovery without conflating absence and failure" do
    value = described_class.or_else(Type.new("!?Int64"), Type.new(:Int64))
    raise_plan = described_class.or_else(
      Type.new("!?Int64"), Type.new(:NoReturn),
      operation: TenseOperationKind::OrElseRaise, recovery: TenseRecovery::Raise,
    )
    optional_raise = described_class.or_else(
      Type.new("?Int64"), Type.new(:NoReturn),
      operation: TenseOperationKind::OrElseRaise, recovery: TenseRecovery::Raise,
    )

    expect(Type.surface_name(value.result_type)).to eq("Int64")
    expect(value.backend_form).to eq(TenseBackendForm::ZigCatch)
    expect(value.recovery).to eq(TenseRecovery::Fallback)
    expect(value.recovery_operation?).to be(true)
    expect(Type.surface_name(raise_plan.result_type)).to eq("?Int64")
    expect(raise_plan.may_terminate_current_flow).to be(true)
    expect(Type.surface_name(optional_raise.result_type)).to eq("?Int64")
    expect(optional_raise.backend_form).to eq(TenseBackendForm::ZigOptionalFallback)
    expect { described_class.or_else(Type.new(:Int64), Type.new(:Int64)) }.to(
      raise_error(ArgumentError, /recoverable outer layer/),
    )
    expect { described_class.or_else(Type.new("?Int64"), Type.new(:String)) }.to(
      raise_error(ArgumentError, /does not match/),
    )
  end

  it "centralizes all async-join success and failure outcomes" do
    expect(described_class.join_async_results([]).reason).to eq(:empty)
    expect(Type.surface_name(T.must(described_class.join_async_results([Type.new(:NIL)]).result_type))).to eq("NIL")
    expect(described_class.join_async_results([Type.new(:NIL), Type.new("~Int64")]).reason).to eq(:future_mismatch)
    expect(described_class.join_async_results([Type.new(:Int64), Type.new("~Int64")]).reason).to eq(:future_mismatch)
    expect(described_class.join_async_results([Type.new(:Int64), Type.new(:String)]).reason).to eq(:payload_mismatch)

    joined = described_class.join_async_results([Type.new("~Int64"), Type.new("~!?Int64")])
    expect(joined.success?).to be(true)
    expect(Type.surface_name(T.must(joined.result_type))).to eq("~!?Int64")
  end

  it "publishes one immutable plan for each migrated source operation" do
    source = <<~CLEAR
      FN risky() RETURNS !Int64 -> RETURN 1; END
      FN maybe() RETURNS ?Int64 -> RETURN 2; END
      FN main() RETURNS !Void ->
        tried = TRY risky();
        unwrapped = UNWRAP maybe();
        recovered = risky() OR_ELSE 3;
        okay = risky() IS_OK;
        present = maybe() EXISTS;
        future:~ = BG { 4; };
        awaited = NEXT future;
        RETURN;
      END
    CLEAR

    body = annotated_function(source, "main").body
    expected = [
      TenseOperationKind::Try,
      TenseOperationKind::Unwrap,
      TenseOperationKind::OrElseValue,
      TenseOperationKind::IsOk,
      TenseOperationKind::Exists,
      nil,
      TenseOperationKind::Next,
    ]
    actual = body.first(7).map do |statement|
      value = T.cast(statement, AST::BindExpr).value
      plan = T.cast(value.tense_plan, T.nilable(TenseOperationPlan))
      plan&.operation
    end

    expect(actual).to eq(expected)
    actual_plans = body.first(7).filter_map do |statement|
      T.cast(T.cast(statement, AST::BindExpr).value.tense_plan, T.nilable(TenseOperationPlan))
    end
    expect(actual_plans).to all(satisfy { |plan| !plan.respond_to?(:operation=) && !plan.respond_to?(:result_type=) })
  end
end
