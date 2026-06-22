pub struct RustSourceFactBehavior {
    value: Option<String>,
    callback: Callback,
}

impl RustSourceFactBehavior {
    pub fn update(&mut self, input: Option<String>, enabled: bool) -> Option<String> {
        let mut result = String::new();
        let mut local = input;

        if local.is_none() {
            panic!("missing input");
        }

        if local.is_some() && enabled {
            self.value = local;
            self.callback();
            std::fs::read_to_string("config").ok();
            println!("{}", result);
        }

        result.push_str("done");
        Some(result)
    }

    fn none_ready(&self) -> bool {
        self.value.is_none()
    }
}
