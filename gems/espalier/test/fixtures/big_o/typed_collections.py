def copy_if_present(values: list[str]) -> list[str]:
    if values.count("needle"):
        return values.copy()
    return []
