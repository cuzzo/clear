CREATE TABLE users (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  bonus INTEGER,
  age INTEGER NOT NULL
);

CREATE TABLE subscriptions (
  user_id INTEGER,
  status TEXT
);
