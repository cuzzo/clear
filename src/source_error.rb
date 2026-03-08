module ErrorDefinitions
  MESSAGES = {
    # PARSER ERRORS
    UNEXPECTED_TOKEN: "Unexpected token '%s' (%s). Expected an expression or statement.",
    INVALID_ASSIGNMENT: "Invalid assignment target. You can only SET variables, fields, or indices.",
    MISSING_CAST_TYPE: "Syntax Error: CAST expects a Type identifier after 'AS', got %s.",
    UNKNOWN_OPERATOR: "Unknown operator '%s'.",

    # COMPILER ERRORS
    ILLEGAL_BREAK: "'BREAK' used outside of a loop.",
    ILLEGAL_CONTINUE: "'CONTINUE' used outside of a loop.",

    HEAP_PRIMITIVE: "VAR '%s' is a primitive. Cannot allocate on HEAP. Remove the `%` sigil to allocate on STACK.",
    UNDEFINED_VAR: "Undefined variable '%s'.",
    UNRECOGNIZED_LITERAL: "Unrecognized literal: %s",
    IMMUTABLE_ASSIGNMENT: "Variable '%s' is immutable.",
    VARIABLE_REBIND: "Cannot rebind immutable variable '%s'.",

    NATIVE_CALL_ERROR: "native_call requires 'Class' and 'Method' string literals.",
    MISSING_FIELD_VALUE: "Missing value for field '%s' in struct '%s'",
    MISSING_REQUIRED_STRUCT_FIELD: "Missing required field '%s' in instantiation of '%s'",
    VARIABLE_ASSIGNMENT_TYPE_ERROR: "Type Error: Variable '%s' declared as %s but assigned %s",
    FIXED_ARRAY_SIZE_AS_DYNAMIC: "Cannot initialize fixed-array '%s' to an unknown size. You must TRUNCATE to a specific size, or use `[]` to create a dynamic array.",
    FIXED_ARRAY_SIZE_MISMATCH: "Cannot initialize array of size %d to fixed-size '%s'",
    SET_UNDECLARED_VAR: "Cannot SET '%s' because it has not been declared with VAR.",

    IMMUTABLE_FIELD_ASSIGNMENT: "Cannot modify field '%s' of immutable object '%s'.",
    IMMUTABLE_LIST_ASSIGNMENT: "Cannot modify index of immutable list '%s'.",
    LIST_TYPE_MISMATCH: "List contains mixed types. Item %d is '%s', expected '%s'.",
    ILLEGAL_FIELD_LOOKUP: "Type Error: Cannot determine struct type for field access '%s'. Object is '%s'.",
    STRUCT_FIELD_UNRESOLVABLE: "Type Error: Struct '%s' has no field '%s'",
    ENUM_UNKNOWN_VARIANT:      "Type Error: Enum '%s' has no variant '%s'.",
    ENUM_FIELD_ACCESS:         "Type Error: '%s' is an enum type. Enum values do not have fields.",
    UNION_UNKNOWN_VARIANT:     "Type Error: Union '%s' has no variant '%s'.",
    UNION_PAYLOAD_MISMATCH:    "Type Error: Union variant '%s' expects %s, got %s.",
    UNION_FIELD_ACCESS:        "Type Error: '%s' is a union type. Access variants with 'Type.Variant(payload)'.",

    GENERIC_DUPLICATE_TYPE_PARAM: "Type Error: Duplicate type parameter '%s' in generic struct '%s'.",
    GENERIC_TYPE_PARAM_SHADOWS_BUILTIN: "Type Error: Type parameter '%s' shadows built-in type '%s'.",

    # FUNCTION ERRORS
    MISSING_FUNCTION: "Missing function '%s'.",
    ARITY_MISMATCH: "Function '%s' expects %d arguments, got %d.",
    ARITY_MISMATCH_RANGE: "Function '%s' expects between %d and %d arguments, got %d.",
    ARGUMENT_TYPE_ERROR: "Type Error: Function '%s' argument %d expects %s, got %s",
    PRIMITIVE_PASSED_AS_MUTABLE: "Parameter '%s' is MUTABLE but has primitive type '%s'. Primitives are passed by value, so mutating them locally has no effect on the caller.",
    IMMUTABLE_ARG_PASSED_AS_MUTABLE: "Argument %d ('%s') is MUTABLE, but you passed immutable variable '%s'.",
    IMMUTABLE_ARG_PASSED_AS_EXPRESSION: "Argument %d ('%s') is MUTABLE. You cannot pass a value/expression, you must pass a Mutable Variable.",
    ILLEGAL_UPVALUE: "Cannot capture '%s' - undefined in outer scope.",
    RETURN_MISMATCH: "Type Error: Function expected to return '%s', but returned '%s'",
  }
end

module ErrorHelper
  include ErrorDefinitions

  # usage: error(node, :CODE, arg1, arg2)
  def error!(node_or_token, code_or_message, *args)
    # 1. Extract the Token (works for AST Node or raw Token)
    token = node_or_token.respond_to?(:token) ? node_or_token.token : node_or_token

    # 2. Determine Message
    if code_or_message.is_a?(Symbol)
      # A. Look up the template
      template = MESSAGES[code_or_message]
      raise "Internal Compiler Error: Unknown error code :#{code_or_message}" unless template

      # B. Format the string using the passed args
      # This uses Ruby's standard sprintf logic
      begin
        message = template % args
      rescue ArgumentError
        # Fallback if you passed the wrong number of arguments in code
        message = template + " [Internal Args Error: #{args.inspect}]"
      end
    else
      # C. Legacy Support (Raw String)
      message = code_or_message
    end

    # 3. Raise the specific error class
    # We assume 'self.class' has a method 'error_class' (see step 3)
    # OR we just check the class name.
    err_class = self.class.name.include?("Parser") ? ParserError : CompilerError

    raise err_class.new(token, message, @source_code)
  end
end

class SourceError < StandardError
  attr_reader :token, :original_message, :source_code

  def initialize(token, message, source_code)
    @token = token
    @original_message = message
    @source_code = source_code
    super(build_message)
  end

  # Child classes override this for the header title
  def error_type; "Error"; end

  private

  def build_message
    # Handle EOF or missing token
    if @token.nil? || @token.type == :EOF
      return "\n\e[31m[#{error_type}]\e[0m #{@original_message} (at End of File)\n"
    end

    line_num = @token.line
    col_num = @token.column

    return "[#{error_type}] #{@original_message} (Line #{line_num})" if @source_code.nil? || @source_code.empty?

    lines = @source_code.split("\n")
    raw_line = lines[line_num - 1] || ""

    # 1. Header
    out = "\n\e[31m[#{error_type}]\e[0m #{@original_message}\n"
    out += "\e[90mLocation:\e[0m Line #{line_num}, Column #{col_num}\n\n"

    # 2. The Code Snippet
    gutter_width = line_num.to_s.length
    out += "  #{' ' * gutter_width} | \n"
    out += "  #{line_num} | #{raw_line}\n"

    # 3. The Caret
    prefix = raw_line[0...col_num-1] || ""
    visual_offset = prefix.gsub("\t", "  ").length

    out += "  #{' ' * gutter_width} | \e[31m#{' ' * visual_offset}^\e[0m\n"
    out += "  #{' ' * gutter_width} | \n"

    out
  end
end

class ParserError < SourceError
  def error_type; "Parser Error"; end
end

class CompilerError < SourceError
  def error_type; "Compiler Error"; end
end

