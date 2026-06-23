fn method_two() {
    let result = (|| -> Result<(), Error> {
        return Err(Error);
    })();
    match result {
        Err(e) => log(e),
        _ => {}
    }
    cleanup();
}
