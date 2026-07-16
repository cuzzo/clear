interface Client {
  name?: string | null;
  fetch(value: string | null): string | null;
}

class Worker {
  call(value: string | null): string | null {
    return value;
  }
}
