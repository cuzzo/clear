// typescript_sample.ts

class Database {
    public port: number = 5432;
}

class Greeter {
    private _db: Database;
    constructor(db: Database) {
        this._db = db;
    }

    public hello(name: string): string {
        return `Hello ${name}`;
    }
}
