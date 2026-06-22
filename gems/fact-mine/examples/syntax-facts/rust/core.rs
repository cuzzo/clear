pub struct RustSyntaxFactsCore {
    status: Status,
    count: usize,
}

pub enum Status {
    Idle,
    Busy,
}

impl RustSyntaxFactsCore {
    pub fn new(status: Status) -> Self {
        Self { status, count: 0 }
    }

    pub fn process(
        &mut self,
        user: &User,
        items: Vec<Item>,
        callback: fn(&Account),
    ) -> Option<String> {
        let name = user.profile().name().to_string();
        let account = Account::new(name.clone(), user.active());
        callback(&account);

        match user.role() {
            Role::Owner | Role::Admin => self.escalate(user),
            Role::Guest => self.fallback(user),
            _ => self.default_case(user),
        }

        if matches!(self.status, Status::Idle) && user.ready() {
            self.count += 1;
            self.publish(Status::Busy);
        } else {
            self.warn("not ready");
        }

        for item in items {
            item.children();
        }

        Some(name)
    }

    fn audit(&self, name: &str) {
        println!("{}", name);
        self.send("record", name);
        self.status();
    }

    fn ready(&self) -> bool {
        self.count > 0
    }
}

