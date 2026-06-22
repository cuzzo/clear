using System;
using System.Collections.Generic;

class CSharpSyntaxFactsCore
{
    private Status status;
    private int count;
    private Sink sink;

    public CSharpSyntaxFactsCore(Status status, Sink sink)
    {
        this.status = status;
        this.count = 0;
        this.sink = sink;
    }

    public string Process(User user, IEnumerable<Item> items, Action<Account> callback)
    {
        var name = user.Profile.Name;
        var account = new Account(name, user.Active);
        callback(account);

        switch (user.Role)
        {
            case "owner":
            case "admin":
                Escalate(user);
                break;
            case "guest":
                Fallback(user);
                break;
            default:
                DefaultCase(user);
                break;
        }

        if (this.status == Status.Idle && user.Ready)
        {
            this.count += 1;
            Publish(Status.Busy);
        }
        else
        {
            Console.WriteLine("not ready");
        }

        foreach (var item in items)
        {
            item.Children();
        }

        return name;
    }

    private Status Audit(string name)
    {
        Console.WriteLine(name);
        sink.Send("record", name);
        return status;
    }

    private bool Ready()
    {
        return count > 0;
    }
}

