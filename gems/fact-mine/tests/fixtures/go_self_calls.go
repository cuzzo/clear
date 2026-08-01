package selfcalls

type Element struct {
	next, prev *Element
	Value      any
}

type List struct {
	root Element
	len  int
}

func (l *List) lazyInit() {
	if l.root.next == nil {
		l.root.next = &l.root
	}
}

func (l *List) insert(e, at *Element) *Element {
	e.prev = at
	l.len++
	return e
}

func (l *List) insertValue(v any, at *Element) *Element {
	return l.insert(&Element{Value: v}, at)
}

func (l *List) PushBack(v any) *Element {
	l.lazyInit()
	return l.insertValue(v, l.root.prev)
}

func rawHelper(x int) int {
	return x + 1
}

func rawCaller(x int) int {
	return rawHelper(x)
}
