CREATE TABLE users (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  bonus INTEGER,
  age INTEGER
);

INSERT INTO users (id, name, bonus, age) VALUES
  (1, 'Alice', 500, 30),
  (2, 'Bob', 0, 20),
  (3, 'Charlie', NULL, 17),
  (4, 'Dana', 100, NULL);
