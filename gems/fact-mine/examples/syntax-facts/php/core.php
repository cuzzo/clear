<?php

class PhpSyntaxFactsCore
{
    private string $status;
    private int $count = 0;
    private $sink;

    public function __construct(string $status, $sink)
    {
        $this->status = $status;
        $this->sink = $sink;
    }

    public function process($user, array $items, callable $callback): ?string
    {
        $name = $user?->profile?->name;
        $account = new Account($name, $user->active);
        $callback($account);

        switch ($user->role) {
            case "owner":
            case "admin":
                $this->escalate($user);
                break;
            case "guest":
                $this->fallback($user);
                break;
            default:
                $this->defaultCase($user);
                break;
        }

        if ($this->status === "idle" && $user->ready) {
            $this->count += 1;
            $this->publish("busy");
        } else {
            print "not ready";
        }

        foreach ($items as $item) {
            $item->children();
        }

        return $name ?? null;
    }

    private function audit(string $name): string
    {
        print($name);
        $this->sink->send("record", $name);
        return $this->status;
    }

    public function ready(): bool
    {
        return $this->count > 0;
    }

    public function metaprogrammingDemo(): void
    {
        eval('1+1');
        $f = 'bar';
        $$f = 1;
        new ReflectionClass('Foo');
    }

    public function __get($name)
    {
        return null;
    }
}

