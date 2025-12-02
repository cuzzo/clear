module OpCodes
  # Parameter Types
  T_REG_W = :reg_w  # Register Write (Target) - e.g. "R0"
  T_REG_R = :reg_r  # Register Read (Target)  - e.g. "R0"
  T_CONST = :const  # Constant Index          - e.g. "K0"

  DEFINITIONS = {
    # OPCODE      # PARAMS
    LOADK:        [T_REG_W, T_CONST],
    MOVE:         [T_REG_W, T_REG_R],
  }
end
