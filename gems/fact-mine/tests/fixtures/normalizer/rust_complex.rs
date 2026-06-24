fn main() {
    let x = match 1 {
        1 => 2,
        _ => 3,
    };
    
    loop {
        break;
    }
    
    if let Some(y) = Some(1) {
        println!("{}", y);
    }
}
