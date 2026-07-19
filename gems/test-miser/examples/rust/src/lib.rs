pub fn classify(value: i32) -> &'static str {
    if value > 10 {
        "high"
    } else if value > 0 {
        "positive"
    } else {
        "nonpositive"
    }
}

#[cfg(test)]
mod tests {
    use super::classify;

    #[test]
    fn positive_primary() {
        assert_eq!(classify(5), "positive");
    }

    #[test]
    fn positive_duplicate() {
        assert_eq!(classify(5), "positive");
    }

    #[test]
    fn high() {
        assert_eq!(classify(11), "high");
    }

    #[test]
    fn nonpositive() {
        assert_eq!(classify(0), "nonpositive");
    }

    #[test]
    fn smoke() {
        assert!(true);
    }
}
