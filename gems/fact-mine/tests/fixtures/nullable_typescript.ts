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

  guardedDisjunction(flag: number): number {
    const value: string | undefined = undefined;
    if (value === undefined || flag === 5) {
      return 0;
    } else {
      return value.length;
    }
  }

  shadowedUndefined(): number {
    const undefined = "ready";
    return undefined.length;
  }
}
