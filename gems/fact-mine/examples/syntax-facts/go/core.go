package syntaxfacts

type Status int

const (
	Idle Status = iota
	Busy
)

type Profile struct {
	Name string
}

type User struct {
	Role    string
	Ready   bool
	Active  bool
	Profile Profile
}

type Account struct {
	Name   string
	Active bool
}

type GoSyntaxFactsCore struct {
	status Status
	count  int
	lookup map[string]int
}

func NewGoSyntaxFactsCore(status Status) *GoSyntaxFactsCore {
	return &GoSyntaxFactsCore{status: status, lookup: map[string]int{}}
}

func (c *GoSyntaxFactsCore) Process(user User, items []string, callback func(Account)) string {
	var first, second int = 1, 2
	_ = first
	_ = second

	name := user.Profile.Name
	account := Account{Name: name, Active: user.Active}
	callback(account)

	switch user.Role {
	case "owner", "admin":
		c.escalate(user)
	case "guest":
		c.fallback(user)
	default:
		c.defaultCase(user)
	}

	if c.status == Idle && user.Ready {
		c.count += 1
		c.publish(Busy)
	} else {
		c.warn("not ready")
	}

	for _, item := range items {
		c.children(item)
	}

	c.lookup[name] = c.count
	go c.audit(name)
	defer c.audit(name)

	return name
}

func (c *GoSyntaxFactsCore) audit(name string) {
	println(name)
	c.send("record", name)
	_ = c.status
}

func (c GoSyntaxFactsCore) Ready() bool {
	return c.count > 0
}

