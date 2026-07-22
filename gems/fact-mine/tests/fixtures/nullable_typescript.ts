class NullableTypeScript {
  unsafeNull(): number {
    const value: string | null = null;
    return value.length;
  }

  unsafeUndefined(): number {
    const value: string | undefined = undefined;
    return value.length;
  }

  guarded(): number {
    const value: string | undefined = undefined;
    if (value == undefined) {
      return 0;
    }
    return value.length;
  }

  shadowedUndefined(): number {
    const undefined = "ready";
    return undefined.length;
  }
}
