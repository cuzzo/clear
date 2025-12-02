require_relative "./ast"

module OpCodes
  # Parameter Types
  T_REG_W = :reg_w  # Register Write (Target) - e.g. "R0"
  T_REG_R = :reg_r  # Register Read (Target)  - e.g. "R0"
  T_CONST = :const  # Constant Index          - e.g. "K0"
  T_STR   = :str    # Arbitrary String        - e.g. "main"
  T_RAW   = :raw    # Ruby Native Type        - e.g. {x: Integer} - for def struct
  T_UINT  = :uint   # Raw Integer             - e.g. 25 - Jump Target
  T_REST  = :rest   # Remaining raw args      - e.g. like splatting, for native_call

  DEFINITIONS = {
    # OPCODE      # PARAMS
    LOADK:        [T_REG_W, T_CONST],
    MOVE:         [T_REG_W, T_REG_R],
    NEW_HASH:     [T_REG_W],
    NEW_STRUCT:   [T_REG_W, T_STR],
    SET_FIELD:    [T_REG_R, T_STR, T_REG_R],
    SET_HASH:     [T_REG_R, T_STR, T_REG_R],
    SET_INDEX:    [T_REG_R, T_REG_R, T_REG_R],
    NEW_LIST:     [T_REG_W],
    APPEND:       [T_REG_R, T_REG_R],
    DEF_GLOBAL:   [T_STR, T_REG_R],
    DEF_STRUCT:   [T_STR, T_RAW],
    PRINT:        [T_REG_R],
    FREEZE:       [T_REG_R],
    EXIT_PROGRAM: [T_REG_R],
    JMP:          [T_UINT],
    JMP_FALSE:    [T_REG_R, T_UINT],
    JMP_TRUE:     [T_REG_R, T_UINT],
    JMP_IF_ERROR: [T_REG_R, T_UINT],
    JMP_IF_OK:    [T_REG_R, T_UINT],
    GET_INDEX:    [T_REG_W, T_REG_R, T_REG_R],
    GET_FIELD:    [T_REG_W, T_REG_R, T_STR],
    ASSERT:       [T_REG_R, T_CONST],
    THROW:        [T_REG_R],
    THROW_IF_ERROR: [T_REG_R],
    NOT:          [T_REG_W, T_REG_R],
    CALL_NATIVE:  [T_REG_W, T_STR, T_STR, T_REST],
    NEW_SLICE:    [T_REG_W, T_REG_R, T_REG_R, T_REG_R],
    TAKE_REF:     [T_REG_W, T_REG_R],
    NEW_CLOSURE:  [T_REG_W, T_CONST, T_REST],
    CALL_CLOSURE: [T_REG_W, T_REG_R, T_UINT, T_REST],
    CALL_METHOD:  [T_REG_W, T_REG_R, T_STR, T_REST],
    CALL_FUNC:    [T_REG_W, T_STR, T_UINT, T_REST],
    RETURN:       [T_REG_R],
  }

  AST::OP_CODE_SENDABLE_SYMS.keys.each do |op|
    DEFINITIONS[op] = [T_REG_W, T_REG_R, T_REG_R]
  end
end
