module OpCodes
  # Parameter Types
  T_REG_W = :reg_w  # Register Write (Target) - e.g. "R0"
  T_REG_R = :reg_r  # Register Read (Target)  - e.g. "R0"
  T_CONST = :const  # Constant Index          - e.g. "K0"
  T_STR   = :str    # Arbitrary String        - e.g. "main"
  T_RAW   = :raw    # Ruby Native Type        - e.g. {x: Integer} - for def struct

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
  }
end
