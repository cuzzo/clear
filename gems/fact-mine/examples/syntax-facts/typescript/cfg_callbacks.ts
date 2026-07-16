class CfgCallbacks {
  callbackBlock(user: unknown) {
    this.callback(() => {
      this.audit(user);
    });
    this.finish(user);
  }

  nestedCallback(user: unknown) {
    this.callback(() => {
      this.hook(() => {
        this.audit(user);
      });
    });
    this.finish(user);
  }

  emptyCallback(user: unknown) {
    this.callback(() => {});
    this.finish(user);
  }
}
