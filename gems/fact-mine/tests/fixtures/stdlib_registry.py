def inspect(text: str) -> str:
    if text.endswith("."):
        return text.casefold()
    return text.removeprefix("x")
