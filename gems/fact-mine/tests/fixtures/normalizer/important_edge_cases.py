def foo():
    match x:
        case 1:
            return 1, 2
        case MyConst:
            return obj.method()
        case bare_name:
            return not obj
